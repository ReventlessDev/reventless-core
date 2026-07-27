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
}

let bundledInfos: dict<sliceInfo> = Dict.make()

let dcbQueueUrlRef: ref<option<Pulumi.Output.t<string>>> = ref(None)
let setDcbQueueUrl = url => dcbQueueUrlRef := Some(url)
// The admin/plugin DCB command-topic FIFO URL captured by the
// onDcbCommandTopicCreated hook. Read by the admin EventCollector's reactive
// ApiFragmentRegistry push (2e) to dispatch RecordApiFragmentPush.
let getDcbQueueUrl = () => dcbQueueUrlRef.contents

let registerAutomationSlice = (
  ~name,
  ~specModulePath,
  ~bodyModulePath,
  ~callbackType="automation",
  ~queryDbTableName,
  ~queryDbResources=[],
  ~context=?,
) =>
  bundledInfos->Dict.set(
    name,
    {specModulePath, bodyModulePath, callbackType, queryDbTableName, queryDbResources, context},
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
        let eventTopics: ReventlessCore.EventTopic.allOutputs = Dict.fromArray([
          ("DcbEventLog", dcbOutputs.eventTopic),
        ])
        let channel = EventCollectorChannel.make(
          ~name="AllAutomationSlices",
          ~eventTopics,
          ~owner=None,
          ~opts,
        )

        // One DCB stream URN, identical for every slice on this plugin log — the
        // dispatch key the entry point maps event-source records back to.
        let sourceUrn = switch dcbOutputs.eventTopic.resources->Array.get(0) {
        | Some(resource) => resource.urn
        | None => Pulumi.Output.make("")
        }

        let dcbQueueUrl = switch dcbQueueUrlRef.contents {
        | Some(url) => url
        | None => Pulumi.Output.make("NOT_AVAILABLE")
        }

        let handlerOutputs: array<Pulumi.Output.t<string>> = []
        let packageDirs: dict<string> = Dict.make()
        let allQueryDbResources: array<ReventlessInfra.Adapter.resource> = []

        bundledInfos->Dict.forEachWithKey((info, _name) => {
          info.queryDbResources->Array.forEach(r => allQueryDbResources->Array.push(r)->ignore)
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

          let handlerJson =
            Pulumi.Output.all3((info.queryDbTableName, dcbQueueUrl, sourceUrn))
            ->Pulumi.Output.apply(((tableName, queueUrl, urn)) =>
              `{"specModule":${specModule},"bodyModule":${bodyModule},"callbackType":${callbackType},"queryDbTableName":"${tableName}","dcbQueueUrl":"${queueUrl}","sourceUrn":"${urn}"${contextFragment}}`
            )
          let _ = handlerOutputs->Array.push(handlerJson)
        })

        let handlerConfigOutput =
          Pulumi.Output.all(handlerOutputs)
          ->Pulumi.Output.apply(handlers => `{"handlers":[${handlers->Array.join(",")}]}`)

        let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
        envVars->Dict.set("HANDLER_CONFIG", handlerConfigOutput->Pulumi.Output.asInput)

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
      | None =>
        log.warn(
          ~comp="AutomationSliceRuntime_Builder_Single",
          "finishWithDcbEventLog: DCB EventLog has no parent",
        )
      }
    }
    finished := true
  }
