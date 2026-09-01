module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

let log = ReventlessCore.Logger.fromEnv()

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type sliceInfo = {
  specModulePath: string,
  // The slice's body module (`<Slice>_Automation.res` / `<Slice>_Translation.res`)
  // — the second argument of the curried callback functor
  // (AutomationSlice_Callback.Make(Spec)(Automation)). The entry point must
  // import it alongside the spec; a spec module alone cannot rebuild the
  // callback.
  bodyModulePath: string,
  callbackType: string,
  queryDbTableName: Pulumi.Output.t<string>,
  // The slice's TODO view table resource(s). Passed as the channel `resources`
  // so `connect` grants the Lambda write access to sync todo rows. Captured
  // synchronously at `registerAutomationSlice` time — the finalizer must not
  // depend on the apply-deferred `storedSpecs` (see `finishWithDcbEventLog`).
  queryDbResources: array<ReventlessInfra.Adapter.resource>,
  // Threaded to phase 1 collect/resolve on the automation path (mirrors the
  // in-process builder's `~context`); outbound slices take no context.
  context: option<Reventless.AutomationSlice.context>,
  // The non-DCB topics this slice subscribes to — an Aggregate's EventTopic when
  // it names one by `Spec.name`. Empty for the common DCB-only slice.
  //
  // Captured *synchronously* here for the same reason the whole `bundledInfos`
  // path exists: `forEventCollector` runs inside a `Pulumi.Output.apply`, so
  // `storedSpecs` — which carries the resolved topics on the dead `finish` path
  // — is still empty when `finishWithDcbEventLog` runs. The core builders
  // compute this dict before that apply, so the value is available in time; it
  // just had nowhere to go until now.
  sourceTopics: ReventlessCore.EventTopic.allOutputs,
  // Whether this slice also reads the plugin's own DCB event log. True for every
  // slice that declares no sources (the default) and for any that names the log
  // explicitly, which is why it is not derivable from `sourceTopics` being empty.
  consumesDcbLog: bool,
  // Which component's CommandTopic this slice publishes its inbound command to.
  // `None` keeps the plugin's DCB queue — right for a slice targeting a DCB
  // StateChangeSlice, and what the shared Lambda used unconditionally before an
  // outbound slice could target an Aggregate, whose commands a different Lambda
  // consumes.
  //
  // Resolved in the finalizer rather than here: an Aggregate's CommandTopic is
  // created *after* the slices that target it, so a lookup at registration time
  // finds nothing. Only the name is knowable this early.
  commandTargetName: option<string>,
}

let bundledInfos: dict<sliceInfo> = Dict.make()

let dcbQueueUrlRef: ref<option<Pulumi.Output.t<string>>> = ref(None)
// The DCB command topic's own flavor, for the slices that publish to it. Set
// beside the URL rather than assumed: the runtime publisher used to hardcode
// FIFO, and these queues are standard, which SQS rejects.
let dcbQueueIsFifo = ref(false)
// The DCB command topic queues as deploy-time resources, so the finalizer can
// put them on the channel spec and `connectLambda`'s `sqs:SendMessage` grant
// covers the slices that publish to the DCB fallback. Accumulated rather than
// kept singular: the hook fires once per DCB command topic (sync, and async
// when async StateChangeSlices exist), and granting on both is correct.
let dcbQueueResources: array<ReventlessInfra.Adapter.resource> = []
// First call wins for the URL and flavor. The hook fires once per DCB command
// topic and a plugin with async StateChangeSlices fires it twice; the sync topic
// is created first and is the one a slice's command belongs on, so letting the
// async FIFO topic overwrite would send slice commands to a FIFO queue with no
// MessageGroupId — which SQS rejects. The resources keep accumulating: the grant
// is wanted on every DCB command topic.
let setDcbQueueUrl = (~isFifo=false, ~resource=?, url) => {
  if dcbQueueUrlRef.contents->Option.isNone {
    dcbQueueUrlRef := Some(url)
    dcbQueueIsFifo := isFifo
  }
  resource->Option.forEach(r => dcbQueueResources->Array.push(r)->ignore)
}
// The admin/plugin DCB command-topic FIFO URL captured by the
// onDcbCommandTopicCreated hook. Read by the admin EventCollector's reactive
// ApiFragmentRegistry push (2e) to dispatch RecordApiFragmentPush.
let getDcbQueueUrl = () => dcbQueueUrlRef.contents

// `~sourceTopics` / `~consumesDcbLog` default to the DCB-only shape every slice
// had before aggregate sources existed, so a caller that has not been updated
// keeps exactly its previous wiring.
let registerAutomationSlice = (
  ~name,
  ~specModulePath,
  ~bodyModulePath,
  ~callbackType="automation",
  ~queryDbTableName,
  ~queryDbResources=[],
  ~context=?,
  ~sourceTopics=Dict.make(),
  ~consumesDcbLog=true,
  ~commandTargetName=?,
) =>
  bundledInfos->Dict.set(
    name,
    {
      specModulePath,
      bodyModulePath,
      callbackType,
      queryDbTableName,
      queryDbResources,
      context,
      sourceTopics,
      consumesDcbLog,
      commandTargetName,
    },
  )

type storedSpec = {
  componentName: string,
  parentResource: Pulumi.Resource.t,
  sourceUrns: Pulumi.Output.t<array<string>>,
  channelSpec: ReventlessCore.EventCollector_Adapter.channelSpec<
    EventCollectorChannel.callbackEvent,
    context,
    EventCollectorChannel.channelParts,
  >,
  memorySize: int,
  timeout: int,
}

let storedSpecs: array<storedSpec> = []
let grandParent = ref(None)

let forEventCollector: ReventlessCore.Runtime.forEventCollector<
  ReventlessCore.Runtime.effectHandler<
    EventCollectorChannel.callbackEvent,
    context,
    unit,
    string,
  >,
  ReventlessCore.EventCollector.component,
> = (
  ~handler as _,
  ~eventTopics,
  ~resources,
  ~memorySize=1024,
  ~timeout=30,
  eventCollector,
) => {
  let eventCollectorResource = eventCollector->ReventlessCore.Component.toPulumiResource
  let channel = eventCollector->ReventlessCore.EventCollector_Adapter.channel
  let eventCollectorName = eventCollectorResource.name->Option.getOr("Unnamed")

  switch eventCollectorResource.parent {
  | Some(parentResource) =>
    let parentName = parentResource.name->Option.getOr("Unnamed")
    if grandParent.contents == None {
      grandParent := parentResource.parent
    }

    let sourceUrns =
      (eventCollector->ReventlessCore.Component.outputs).resources
      ->Array.map(({urn}) => urn)
      ->Pulumi.Output.all

    storedSpecs
    ->Array.push({
      componentName: parentName,
      parentResource,
      sourceUrns,
      channelSpec: {channel, eventTopics, resources},
      memorySize,
      timeout,
    })
    ->ignore

    log.info(
      ~comp="AutomationSliceRuntime_Builder_Single",
      `registered ${eventCollectorName} for ${parentName}`,
    )
  | None =>
    JsError.throwWithMessage(
      `forEventCollector(single): eventCollector ${eventCollectorName} has no parent`,
    )
  }
}

// How often the shared automation Lambda is invoked with no records, to work
// its slices' TODO backlogs.
//
// Without it a backlog only moves when the *next event* arrives, so a slice
// whose traffic stops holds its failed items indefinitely — and D4's "retried to
// maxRetries, then swept" is what an outbound slice is chosen for over a
// hand-rolled Task. Five minutes is short enough that a transient outage clears
// on its own without anyone watching, and long enough that the invocations are
// noise against the event traffic (~288/day per deployment, most of them finding
// an empty backlog and exiting).
let sweepIntervalMinutes = 5

// The scheduled trigger: a rule, permission for EventBridge to invoke, and a
// target carrying the constant payload the entry point's shell branches on. The
// payload is the whole event — a scheduled invocation has no `records`, which is
// exactly how the shell tells the two apart.
let makeSweepSchedule = (~runtime: ReventlessCore.Runtime.environment<runtimeParts>, ~opts) => {
  let name = "AllAutomationSlicesSweep"
  let customOpts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let rule = {
    open PulumiAws.Cloudwatch
    EventRule.make(
      ~name=Pulumi.Pulumi.getStackName() ++ ("-" ++ name),
      ~args={
        description: "Work the automation/outbound slices' TODO backlogs"->Pulumi.Input.make,
        scheduleExpression: EventRule.ScheduleExpression.every(sweepIntervalMinutes->Minutes),
        tags: AWS.Tags.make(
          ~name=Pulumi.Pulumi.getStackName() ++ ("-" ++ name),
          ~kind=ReventlessCore.ComponentType.AutomationSlice,
          ~role=Scheduler,
          ~component=name,
        ),
      },
      ~opts=customOpts,
    )
  }

  // The permission and target need the Lambda's resolved arn/name, so they stay
  // inside an apply — the same shape the plugin heartbeat's runner uses.
  let _permissionAndTarget =
    (
      runtime.parts.lambda->Pulumi.Output.flatMap(l => l.arn),
      runtime.parts.lambda->Pulumi.Output.flatMap(l => l.name),
    )
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((lambdaArn, lambdaName)) => {
      let _permission = PulumiAws.Lambda.Permission.make(
        ~name,
        ~args={
          action: "lambda:InvokeFunction",
          function: lambdaName->Pulumi.Input.make,
          principal: AWS.CloudwatchEventRule.principal,
        },
        ~opts=customOpts,
      )
      let _target = {
        open PulumiAws.Cloudwatch
        EventTarget.make(
          ~name,
          ~args={
            rule: EventTarget.Rule.ofEventRule(rule),
            arn: lambdaArn->Pulumi.Input.make,
            input: `{"reventlessSweep":true}`->Pulumi.Input.make,
          },
          ~opts=customOpts,
        )
      }
    })
}

// Least-privilege `geo:SearchPlaceIndexForText` on the platform's place index,
// for the slices that call the geocoder through the injected capability.
//
// Only attached when the platform actually provisioned an index — that bit is a
// plain bool and therefore known synchronously, while the index *name* is an
// Output. Without the split this would either grant on a nonsense ARN or need
// `option<Pulumi.Output.t<_>>`, which corrupts the Output proxy.
//
// The RolePolicy is created at top level with an Output-valued document, not
// inside an `apply`. A resource created in an apply callback does not reliably
// register with the engine — the same defect that intermittently left the
// heartbeat Lambda without its SQS grant.
let makeGeocoderGrant = (~runtime: ReventlessCore.Runtime.environment<runtimeParts>, ~opts) =>
  if PluginRuntime_Builder.geocoderProvisioned() {
    let customOpts =
      opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
    let policyJson =
      PluginRuntime_Builder.geocoderPlaceIndex()->Pulumi.Output.apply(idx => {
        open PulumiAws.PolicyDocument
        PulumiAws.PolicyDocument.make(
          ~id="AllAutomationSlicesGeocode",
          ~statements=[
            {
              sid: "AllowGeocode",
              effect: Allow,
              actions: Action("geo:SearchPlaceIndexForText"),
              // Account/region wildcarded, matching the Function URL handler's
              // own policy: the index name is what identifies it, and the stack
              // has no other account to reach.
              resources: Resource(`arn:aws:geo:*:*:place-index/${idx}`),
            },
          ],
        )->PulumiAws.PolicyDocument.toJsonString
      })
    let _ = PulumiAws.IAM.RolePolicy.make(
      ~name="AllAutomationSlicesGeocode",
      ~args={
        policy: policyJson->Pulumi.Output.asInput,
        role: runtime.parts.lambdaRole.id->Pulumi.Output.asInput,
      },
      ~opts=customOpts,
    )
  }

// Least-privilege `ses:SendEmail` on the platform's verified sender identity,
// for the slices that send through the injected messaging capability. Built the
// same way as the geocoder grant above, and for the same three reasons: the
// provisioned bit is a plain bool, the address is an Output, and the RolePolicy
// is created at top level rather than inside an `apply`.
let makeMessagingGrant = (~runtime: ReventlessCore.Runtime.environment<runtimeParts>, ~opts) =>
  if PluginRuntime_Builder.messagingProvisioned() {
    let customOpts =
      opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
    let policyJson =
      PluginRuntime_Builder.messagingSender()->Pulumi.Output.apply(sender => {
        open PulumiAws.PolicyDocument
        PulumiAws.PolicyDocument.make(
          ~id="AllAutomationSlicesSendEmail",
          ~statements=[
            {
              sid: "AllowSendEmail",
              effect: Allow,
              // SESv2's SendEmail authorizes against the v1 action name, and the
              // resource is the identity the message is sent FROM — not the
              // recipient, which is why one grant covers every destination.
              actions: Action("ses:SendEmail"),
              resources: Resource(`arn:aws:ses:*:*:identity/${sender}`),
            },
          ],
        )->PulumiAws.PolicyDocument.toJsonString
      })
    let _ = PulumiAws.IAM.RolePolicy.make(
      ~name="AllAutomationSlicesSendEmail",
      ~args={
        policy: policyJson->Pulumi.Output.asInput,
        role: runtime.parts.lambdaRole.id->Pulumi.Output.asInput,
      },
      ~opts=customOpts,
    )
  }

let finished = ref(false)

// Legacy finalizer, kept only to satisfy `EventCollectorRuntime_Builder.T`.
// It is gated on `storedSpecs`, which the core `AutomationSlice_Builder`
// populates via `forEventCollector` *inside a `Pulumi.Output.apply`* — i.e.
// asynchronously. The platform's `onDcbSlicesCreated` hook runs synchronously,
// so at call time `storedSpecs` is still empty and no Lambda is ever built.
// The DCB platform path uses `finishWithDcbEventLog` instead, which drives off
// the synchronously-registered `bundledInfos`. Mirrors StateViewSlice's split.
let finish = () =>
  if !finished.contents {
    if storedSpecs->Array.length > 0 {
      let (maxMemorySize, maxTimeout) = storedSpecs->Array.reduce((0, 0), (
        (accMemorySize, accTimeout),
        {memorySize, timeout},
      ) => {
        (Math.Int.max(accMemorySize, memorySize), Math.Int.max(accTimeout, timeout))
      })

      switch grandParent.contents {
      | Some(parent) =>
        let opts = {Pulumi.ComponentResource.parent: parent}

        let handlerOutputs: array<Pulumi.Output.t<string>> = []
        let packageDirs: dict<string> = Dict.make()

        let dcbQueueUrl = switch dcbQueueUrlRef.contents {
        | Some(url) => url
        | None => Pulumi.Output.make("NOT_AVAILABLE")
        }

        storedSpecs->Array.forEach(spec => {
          switch bundledInfos->Dict.get(spec.componentName) {
          | Some(info) =>
            let pkg = Util_Bundle.extractPackageName(info.specModulePath)
            packageDirs->Dict.set(pkg, Util_Bundle.resolvePackageRoot(pkg))
            // Usually the same package as the spec, but bundle it explicitly —
            // the entry point imports the body module by specifier too.
            let bodyPkg = Util_Bundle.extractPackageName(info.bodyModulePath)
            packageDirs->Dict.set(bodyPkg, Util_Bundle.resolvePackageRoot(bodyPkg))

            let specModule =
              info.specModulePath->JSON.stringifyAny->Option.getOr(`""`)
            let bodyModule =
              info.bodyModulePath->JSON.stringifyAny->Option.getOr(`""`)
            let callbackType =
              info.callbackType->JSON.stringifyAny->Option.getOr(`""`)
            let contextFragment = switch info.context {
            | Some(context) =>
              context
              ->JSON.stringifyAny
              ->Option.map(json => `,"context":${json}`)
              ->Option.getOr("")
            | None => ""
            }

            let handlerJson =
              Pulumi.Output.all3((info.queryDbTableName, dcbQueueUrl, spec.sourceUrns))
              ->Pulumi.Output.apply(((tableName, queueUrl, urns)) => {
                let sourceUrn = urns->Array.getUnsafe(0)
                `{"specModule":${specModule},"bodyModule":${bodyModule},"callbackType":${callbackType},"queryDbTableName":"${tableName}","dcbQueueUrl":"${queueUrl}","sourceUrn":"${sourceUrn}"${contextFragment}}`
              })
            let _ = handlerOutputs->Array.push(handlerJson)
          | None =>
            log.warn(
              ~comp="AutomationSliceRuntime_Builder_Single",
              `no bundled info registered for ${spec.componentName}`,
            )
          }
        })

        let handlerConfigOutput =
          Pulumi.Output.all(handlerOutputs)
          ->Pulumi.Output.apply(handlers =>
            `{"handlers":[${handlers->Array.join(",")}]}`
          )

        let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
        envVars->Dict.set("HANDLER_CONFIG", handlerConfigOutput->Pulumi.Output.asInput)
        // Deploy-derived capability endpoints — a geocoder URL today. Plugin-wide
        // rather than per-handler, which is why they sit here and not inside
        // HANDLER_CONFIG: this is one shared Lambda and every slice on it reaches
        // the same capability. A capability the platform did not provision arrives
        // as "", which its client reads as "not configured" and reports as a
        // retryable `Unavailable` — a modelled outcome rather than a missing
        // variable that fails as a crash.
        PluginRuntime_Builder.capabilityEnv()->Array.forEach(((name, value)) =>
          envVars->Dict.set(name, value->Pulumi.Output.asInput)
        )

        let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
          ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/AutomationSliceEntryPoint.mjs",
          ~packageDirs,
        )

        let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
          ~name="AllAutomationSlices",
          ~unitKind=ReventlessCore.Monitoring.Reactor,
          ~componentKind=ReventlessCore.ComponentType.AutomationSlice,
          ~code,
          ~sourceCodeHash,
          ~envVars,
          ~memorySize=maxMemorySize,
          ~timeout=maxTimeout,
          ~opts,
        )

        let channelSpecs = storedSpecs->Array.map(({channelSpec}) => channelSpec)
        let _connectResources = EventCollectorChannel.connect(
          ~name="AllAutomationSlices",
          ~channelSpecs,
          ~runtime,
          ~opts,
        )
      | None =>
        log.warn(
          ~comp="AutomationSliceRuntime_Builder_Single",
          `finish: grandParent not set`,
        )
      }
    }
    finished := true
  }

// The finalizer the platform actually calls (Platform.res `onDcbSlicesCreated`).
// Mirrors `StateViewSliceRuntime_Builder_Single.finishWithDcbEventLog`: it drives
// off the synchronously-populated `bundledInfos` (never the apply-deferred
// `storedSpecs`) and builds a single channel from the plugin's DCB EventLog
// stream — the sole source for automation/outbound slices, which dispatch by
// `meta.service` inside the callback. `dcbEventLog` is passed so the parent and
// the stream URN are available synchronously here.
let finishWithDcbEventLog = (dcbEventLog: ReventlessCore.DcbEventLog.component) =>
  if !finished.contents {
    if bundledInfos->Dict.keysToArray->Array.length > 0 {
      let dcbResource = dcbEventLog->ReventlessCore.Component.toPulumiResource
      switch dcbResource.parent {
      | Some(parent) =>
        let opts = {Pulumi.ComponentResource.parent: parent}
        let dcbOutputs: ReventlessCore.DcbEventLog.outputs =
          dcbEventLog->ReventlessCore.Component.outputs
        // The plugin's DCB log, plus every Aggregate EventTopic any slice on this
        // Lambda named. One channel spans them all: `connect` turns each topic
        // into its own event-source mapping, and the entry point routes an
        // incoming record to the handlers registered for its stream, so a slice
        // only ever sees the sources it asked for.
        //
        // Keyed `<plugin>DcbEventLog`, the convention `Dcb_Builder` uses when it
        // puts the log into `allEventTopics`. That matters because a slice naming
        // the log explicitly (every DCB-sourced AutomationSlice does) contributes
        // it back under that key: a different key here would leave the same topic
        // in the dict twice, and since an event-source mapping is named after the
        // *topic resource* rather than the key, both would render as
        // `<plugin>DcbEventLog2AllAutomationSlices` and the deploy would fail on a
        // duplicate URN.
        let dcbTopicKey = dcbResource.name->Option.getOr("") ++ "DcbEventLog"
        let eventTopics: ReventlessCore.EventTopic.allOutputs = Dict.fromArray([
          (dcbTopicKey, dcbOutputs.eventTopic),
        ])
        bundledInfos->Dict.forEach(info =>
          info.sourceTopics->Dict.forEachWithKey((topic, key) => eventTopics->Dict.set(key, topic))
        )

        let channel = EventCollectorChannel.make(
          ~name="AllAutomationSlices",
          ~eventTopics,
          ~owner=None,
          ~opts,
        )

        let dcbSourceUrn = switch dcbOutputs.eventTopic.resources->Array.get(0) {
        | Some(resource) => resource.urn
        | None => Pulumi.Output.make("")
        }

        // The stream URNs this one slice listens on — the dispatch keys the entry
        // point maps event-source records back to. Per slice rather than one
        // shared DCB URN, which is what lets an Aggregate-sourced slice exist at
        // all: its events arrive on the Aggregate's stream and would otherwise
        // reach a registry that has never heard of them.
        let sourceUrnsFor = (info: sliceInfo): Pulumi.Output.t<array<string>> => {
          let urns = []
          if info.consumesDcbLog {
            urns->Array.push(dcbSourceUrn)->ignore
          }
          info.sourceTopics
          ->Dict.valuesToArray
          ->Array.forEach(topic =>
            topic.resources->Array.forEach(resource => urns->Array.push(resource.urn)->ignore)
          )
          // Deduped after resolution, because the same stream can be reached two
          // ways — `consumesDcbLog` and an explicit source naming the DCB log.
          // The entry point registers the handler once per URN, so a repeat would
          // run the slice twice for every event: no error, no log, just doubled
          // work and doubled commands.
          urns
          ->Pulumi.Output.all
          ->Pulumi.Output.apply(resolved =>
            resolved->Array.reduce([], (acc, urn) =>
              acc->Array.includes(urn) ? acc : acc->Array.concat([urn])
            )
          )
        }

        let dcbQueueUrl = switch dcbQueueUrlRef.contents {
        | Some(url) => url
        | None => Pulumi.Output.make("NOT_AVAILABLE")
        }

        let handlerOutputs: array<Pulumi.Output.t<string>> = []
        let packageDirs: dict<string> = Dict.make()
        let allQueryDbResources: array<ReventlessInfra.Adapter.resource> = []
        // Whether any slice publishes to the DCB fallback rather than a target
        // aggregate's own topic — if so, that queue needs the SendMessage grant
        // too, once, below the loop.
        let anyDcbFallback = ref(false)

        bundledInfos->Dict.forEachWithKey((info, _name) => {
          info.queryDbResources->Array.forEach(r => allQueryDbResources->Array.push(r)->ignore)
          // The queue this slice publishes its command to. An Aggregate registers
          // its CommandTopic while plugin construction is still synchronous —
          // before DCB construction registers the slices targeting it — so a
          // named target resolves here; anything else keeps the DCB fallback.
          let target = info.commandTargetName->Option.flatMap(CommandTopicRegistry.get)
          switch target {
          | Some({resource}) =>
            // The target CommandTopic joins the channel's resources so
            // `connectLambda`'s existing `sqs:SendMessage` grant covers it.
            allQueryDbResources->Array.push(resource)->ignore
          | None => anyDcbFallback := true
          }
          let pkg = Util_Bundle.extractPackageName(info.specModulePath)
          packageDirs->Dict.set(pkg, Util_Bundle.resolvePackageRoot(pkg))
          // Usually the same package as the spec, but bundle it explicitly —
          // the entry point imports the body module by specifier too.
          let bodyPkg = Util_Bundle.extractPackageName(info.bodyModulePath)
          packageDirs->Dict.set(bodyPkg, Util_Bundle.resolvePackageRoot(bodyPkg))

          let specModule = info.specModulePath->JSON.stringifyAny->Option.getOr(`""`)
          let bodyModule = info.bodyModulePath->JSON.stringifyAny->Option.getOr(`""`)
          let callbackType = info.callbackType->JSON.stringifyAny->Option.getOr(`""`)
          let contextFragment = switch info.context {
          | Some(context) =>
            context
            ->JSON.stringifyAny
            ->Option.map(json => `,"context":${json}`)
            ->Option.getOr("")
          | None => ""
          }

          // Per slice, not plugin-wide: an outbound slice targeting an Aggregate
          // publishes to that aggregate's CommandTopic. Everything else keeps the
          // DCB topic, which is what the field has always meant — and with it the
          // DCB queue's own flavor.
          let (commandQueueUrl, commandQueueIsFifo) = switch target {
          | Some({queueUrl, isFifo}) => (queueUrl, isFifo)
          | None => (dcbQueueUrl, dcbQueueIsFifo.contents)
          }
          let handlerJson =
            Pulumi.Output.all3((info.queryDbTableName, commandQueueUrl, sourceUrnsFor(info)))
            ->Pulumi.Output.apply(((tableName, queueUrl, urns)) => {
              let urnsJson =
                urns->Array.map(JSON.Encode.string)->JSON.Encode.array->JSON.stringify
              // `sourceUrn` stays beside `sourceUrns` so a handler config read by
              // an entry point that predates multi-source still routes its first
              // stream rather than none.
              let firstUrn = urns->Array.get(0)->Option.getOr("")
              let fifoJson = commandQueueIsFifo ? "true" : "false"
              `{"specModule":${specModule},"bodyModule":${bodyModule},"callbackType":${callbackType},"queryDbTableName":"${tableName}","dcbQueueUrl":"${queueUrl}","commandQueueIsFifo":${fifoJson},"sourceUrn":"${firstUrn}","sourceUrns":${urnsJson}${contextFragment}}`
            })
          let _ = handlerOutputs->Array.push(handlerJson)
        })

        // The fallback publishers' grant. Every slice that resolved no target
        // publishes to the plugin's DCB command topic, whose queue was captured
        // by `setDcbQueueUrl` — without this the role has no `sqs:SendMessage`
        // there and every such publish is rejected.
        if anyDcbFallback.contents {
          dcbQueueResources->Array.forEach(r => allQueryDbResources->Array.push(r)->ignore)
        }

        let handlerConfigOutput =
          Pulumi.Output.all(handlerOutputs)
          ->Pulumi.Output.apply(handlers => `{"handlers":[${handlers->Array.join(",")}]}`)

        let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
        envVars->Dict.set("HANDLER_CONFIG", handlerConfigOutput->Pulumi.Output.asInput)
        // Deploy-derived capability endpoints — a geocoder URL today. Plugin-wide
        // rather than per-handler, which is why they sit here and not inside
        // HANDLER_CONFIG: this is one shared Lambda and every slice on it reaches
        // the same capability. A capability the platform did not provision arrives
        // as "", which its client reads as "not configured" and reports as a
        // retryable `Unavailable` — a modelled outcome rather than a missing
        // variable that fails as a crash.
        PluginRuntime_Builder.capabilityEnv()->Array.forEach(((name, value)) =>
          envVars->Dict.set(name, value->Pulumi.Output.asInput)
        )

        let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
          ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/AutomationSliceEntryPoint.mjs",
          ~packageDirs,
        )

        let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
          ~name="AllAutomationSlices",
          ~unitKind=ReventlessCore.Monitoring.Reactor,
          ~componentKind=ReventlessCore.ComponentType.AutomationSlice,
          ~code,
          ~sourceCodeHash,
          ~envVars,
          ~memorySize=1024,
          ~timeout=30,
          ~opts,
        )

        let _connectResources = EventCollectorChannel.connect(
          ~name="AllAutomationSlices",
          ~channelSpecs=[{channel, eventTopics, resources: allQueryDbResources}],
          ~runtime,
          ~opts,
        )

        makeSweepSchedule(~runtime, ~opts)
        makeGeocoderGrant(~runtime, ~opts)
        makeMessagingGrant(~runtime, ~opts)
      | None =>
        log.warn(
          ~comp="AutomationSliceRuntime_Builder_Single",
          "finishWithDcbEventLog: DCB EventLog has no parent",
        )
      }
    }
    finished := true
  }
