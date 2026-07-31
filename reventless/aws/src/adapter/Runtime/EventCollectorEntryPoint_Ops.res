// Typed cold-start core for the Plugin EventCollector Lambda entry point.
//
// The "typed core, thin shell" split (docs/plans/minimize-lambda-entrypoint-mjs-shell.md):
// EventCollectorEntryPoint.mjs owns ONLY the untyped seams — the dynamic
// `import()` of EP/extension/spec modules named in HANDLER_CONFIG and the
// functor applications consuming those runtime-loaded modules
// (ExtensionPoint_Operations.Make, Extension_Operations.Make, the mapping
// factories, patchSpecId). Everything else lives here, fully type-checked:
// HANDLER_CONFIG parsing/validation, the Plugin-RM row projection, the admin
// cross-plugin SNS subscription manager and its cold-start reconciliation, the
// publish/query/scheduler operations, the service-keyed handler-dict assembly,
// Plugin_Callback wiring, and the Lambda dispatch boundary.
//
// Runtime-pure: no `open PulumiAws` values — Pulumi appears in type positions
// only (erased). The two `%identity` casts below sit on documented JSON
// contracts (same pattern as AggregateEntryPoint_Ops.asConnectionConfig).

// ── Shim bindings (HandlerFactoryHelpers.mjs) ───────────────────────────────
// The structured-log + Effect dispatch boundary shared by every deployed entry
// point, and the DynamoDB scan backing the read-model query engine.

type dispatchOpts = {
  correlationId?: string,
  causationId?: string,
  comp?: string,
  timestamp?: float,
  retryCount?: int,
  detail?: string,
}

@module("./HandlerFactoryHelpers.mjs")
external setRequestId: string => unit = "setRequestId"
@module("./HandlerFactoryHelpers.mjs")
external runEffect: (Effect.t<'a, 'e, 'r>, dispatchOpts) => promise<unit> = "runEffect"
@module("./HandlerFactoryHelpers.mjs")
external extractMetaField: (
  array<PulumiAws.Lambda.CallbackFunction.record>,
  string,
) => option<string> = "extractMetaField"
@module("./HandlerFactoryHelpers.mjs")
external extractSentTimestamp: array<PulumiAws.Lambda.CallbackFunction.record> => option<float> =
  "extractSentTimestamp"
@module("./HandlerFactoryHelpers.mjs")
external extractRetryCount: array<PulumiAws.Lambda.CallbackFunction.record> => int =
  "extractRetryCount"
@module("./HandlerFactoryHelpers.mjs") @scope("log")
external logDebug: (string, dispatchOpts) => unit = "debug"
@module("./HandlerFactoryHelpers.mjs") @scope("log")
external logInfo: (string, dispatchOpts) => unit = "info"
@module("./HandlerFactoryHelpers.mjs") @scope("log")
external logWarn: (string, dispatchOpts) => unit = "warn"
@module("./HandlerFactoryHelpers.mjs") @scope("log")
external logError: (string, dispatchOpts) => unit = "error"
@module("./HandlerFactoryHelpers.mjs")
external scanByTableName: (
  string,
  array<Reventless.QueryEngine.Filter.config>,
  int,
) => promise<array<JSON.t>> = "scanByTableName"


let exnMessage = (exn: exn): string =>
  exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown error")

// ── js_nullable normalization ───────────────────────────────────────────────
// pluginDefinition option fields use @s.matches(js_nullable): when the record
// comes from a plain JSON.parse (not a sury parse), None is represented as
// `null` — which ReScript's option (undefined-based) would misread as Some.
// Normalize through Nullable so pattern matches see a real option.

external optionAsNullable: option<'a> => Nullable.t<'a> = "%identity"
let jsOption = (v: option<'a>): option<'a> => v->optionAsNullable->Nullable.toOption

// ── HANDLER_CONFIG ──────────────────────────────────────────────────────────
// Written by PluginRuntime_Builder.forPluginEventCollector; the field-by-field
// schema is documented in EventCollectorEntryPoint.mjs. Explicitly decoded (no
// blanket cast) so defaults land exactly where the former JS normalizer put
// them and a malformed deploy fails with the same named errors.

type extensionPointConfig = {
  specModule: string,
  mappingsModule: string,
  eventTopicArn: string,
  aggregateNames: array<string>,
}
type connectExtensionConfig = {
  specModule: string,
  mappingsModule: string,
  extensionPointName: string,
}
type extensionConfig = {
  name: string,
  specModule: string,
  mappingsModule: string,
  delegateModule: string,
  extensionPointName: string,
  aggregateNames: array<string>,
  readModelNames: array<string>,
}
type handlerConfig = {
  queueUrl: string,
  pluginExtensionPointCmdTopicUrl: string,
  eventTopicArn: string,
  pluginReadModelTableName: string,
  appSyncApiId: string,
  schedulerRoleArn: string,
  schedulerQueueArn: string,
  schedulerQueueName: string,
  extensionPoints: array<extensionPointConfig>,
  connectExtension: option<connectExtensionConfig>,
  extensions: array<extensionConfig>,
  publishToAggregates: dict<string>,
  readModelQueueUrls: dict<string>,
  readModelNamesForSourceName: dict<array<string>>,
}

let strOf = (obj: dict<JSON.t>, key: string): option<string> =>
  obj->Dict.get(key)->Option.flatMap(JSON.Decode.string)
let strArrOf = (obj: dict<JSON.t>, key: string): array<string> =>
  obj->Dict.get(key)->Option.flatMap(JSON.Decode.array)->Option.getOr([])->Array.filterMap(JSON.Decode.string)
let strDictOf = (obj: dict<JSON.t>, key: string): dict<string> =>
  obj
  ->Dict.get(key)
  ->Option.flatMap(JSON.Decode.object)
  ->Option.getOr(Dict.make())
  ->Dict.toArray
  ->Array.filterMap(((k, v)) => v->JSON.Decode.string->Option.map(s => (k, s)))
  ->Dict.fromArray

let parseHandlerConfig = (rawJson: string): handlerConfig => {
  if rawJson == "" {
    JsError.throwWithMessage("HANDLER_CONFIG env var is empty")
  }
  let json = try rawJson->JSON.parseOrThrow catch {
  | exn => JsError.throwWithMessage("HANDLER_CONFIG JSON parse error: " ++ exnMessage(exn))
  }
  let obj = switch json->JSON.Decode.object {
  | Some(o) => o
  | None => JsError.throwWithMessage("HANDLER_CONFIG is not a JSON object")
  }
  [
    "queueUrl",
    "pluginExtensionPointCmdTopicUrl",
    "eventTopicArn",
    "pluginReadModelTableName",
    "appSyncApiId",
    "schedulerRoleArn",
    "schedulerQueueArn",
    "schedulerQueueName",
    "extensionPoints",
    "extensions",
    "publishToAggregates",
  ]->Array.forEach(k =>
    if obj->Dict.get(k)->Option.isNone {
      JsError.throwWithMessage("HANDLER_CONFIG missing required field: " ++ k)
    }
  )
  let extensionPoints = switch obj->Dict.get("extensionPoints")->Option.flatMap(JSON.Decode.array) {
  | None => JsError.throwWithMessage("HANDLER_CONFIG.extensionPoints must be an array")
  | Some(items) =>
    items->Array.filterMap(item =>
      item
      ->JSON.Decode.object
      ->Option.map(ep => {
        specModule: ep->strOf("specModule")->Option.getOr(""),
        mappingsModule: ep->strOf("mappingsModule")->Option.getOr(""),
        eventTopicArn: ep->strOf("eventTopicArn")->Option.getOr(""),
        aggregateNames: ep->strArrOf("aggregateNames"),
      })
    )
  }
  let extensions = switch obj->Dict.get("extensions")->Option.flatMap(JSON.Decode.array) {
  | None => JsError.throwWithMessage("HANDLER_CONFIG.extensions must be an array")
  | Some(items) =>
    items->Array.filterMap(item =>
      item
      ->JSON.Decode.object
      ->Option.map(ext => {
        let extensionPointName = ext->strOf("extensionPointName")->Option.getOr("")
        {
          // Same fallback chain the former JS normalizer applied.
          name: ext
          ->strOf("name")
          ->Option.getOr(extensionPointName == "" ? "unknown" : extensionPointName),
          specModule: ext->strOf("specModule")->Option.getOr(""),
          mappingsModule: ext->strOf("mappingsModule")->Option.getOr(""),
          delegateModule: ext->strOf("delegateModule")->Option.getOr(""),
          extensionPointName,
          aggregateNames: ext->strArrOf("aggregateNames"),
          readModelNames: ext->strArrOf("readModelNames"),
        }
      })
    )
  }
  // connectExtension is null (admin) or absent in older configs — both → None.
  let connectExtension =
    obj
    ->Dict.get("connectExtension")
    ->Option.flatMap(JSON.Decode.object)
    ->Option.map(ce => {
      specModule: ce->strOf("specModule")->Option.getOr(""),
      mappingsModule: ce->strOf("mappingsModule")->Option.getOr(""),
      extensionPointName: ce->strOf("extensionPointName")->Option.getOr(""),
    })
  let readModelNamesForSourceName =
    obj
    ->Dict.get("readModelNamesForSourceName")
    ->Option.flatMap(JSON.Decode.object)
    ->Option.getOr(Dict.make())
    ->Dict.toArray
    ->Array.map(((k, v)) => (
      k,
      v->JSON.Decode.array->Option.getOr([])->Array.filterMap(JSON.Decode.string),
    ))
    ->Dict.fromArray
  {
    queueUrl: obj->strOf("queueUrl")->Option.getOr(""),
    pluginExtensionPointCmdTopicUrl: obj->strOf("pluginExtensionPointCmdTopicUrl")->Option.getOr(""),
    eventTopicArn: obj->strOf("eventTopicArn")->Option.getOr(""),
    pluginReadModelTableName: obj->strOf("pluginReadModelTableName")->Option.getOr(""),
    appSyncApiId: obj->strOf("appSyncApiId")->Option.getOr(""),
    schedulerRoleArn: obj->strOf("schedulerRoleArn")->Option.getOr(""),
    schedulerQueueArn: obj->strOf("schedulerQueueArn")->Option.getOr(""),
    schedulerQueueName: obj->strOf("schedulerQueueName")->Option.getOr(""),
    extensionPoints,
    connectExtension,
    extensions,
    publishToAggregates: obj->strDictOf("publishToAggregates"),
    readModelQueueUrls: obj->strDictOf("readModelQueueUrls"),
    readModelNamesForSourceName,
  }
}

// ── Plugin-RM row projection ────────────────────────────────────────────────
// The subset of the Plugin read-model state the subscription manager needs.
// Deliberately sidesteps sury: the state schema marks many fields
// `@s.matches(js_nullable …)`, but DDB drops undefined attributes on write, so
// the unmarshalled row arrives with those keys *missing* and sury's strict
// parser rejects them. Field types reuse the spec's definition records — the
// projection is a strict subset of Reventless.Plugin.pluginDefinition.

type pluginProjection = {
  id: string,
  status: string,
  eventCollector: string,
  extensions: array<Reventless.Plugin.extensionDefinition>,
  extensionPoints: array<Reventless.Plugin.extensionPointDefinition>,
  dcbEventLog: option<Reventless.Plugin.dcbEventLogDefinition>,
}

let projectPluginRow = (row: JSON.t): option<pluginProjection> =>
  switch row->JSON.Decode.object {
  | None => None
  | Some(obj) =>
    switch (obj->strOf("id"), obj->strOf("status")) {
    | (Some(id), Some(status)) =>
      let dcbEventLog =
        obj
        ->Dict.get("dcbEventLog")
        ->Option.flatMap(JSON.Decode.object)
        ->Option.flatMap(d =>
          switch (d->strOf("name"), d->strOf("eventTopicArn")) {
          | (Some(name), Some(eventTopicArn)) =>
            Some(({name, eventTopicArn}: Reventless.Plugin.dcbEventLogDefinition))
          | _ => None
          }
        )
      let extensions =
        obj
        ->Dict.get("extensions")
        ->Option.flatMap(JSON.Decode.array)
        ->Option.getOr([])
        ->Array.filterMap(e =>
          e
          ->JSON.Decode.object
          ->Option.flatMap(eo =>
            eo
            ->strOf("extensionPointName")
            ->Option.map((extensionPointName): Reventless.Plugin.extensionDefinition => {
              name: eo->strOf("name")->Option.getOr(""),
              extensionPointName,
              dcbSources: eo->strArrOf("dcbSources"),
            })
          )
        )
      let extensionPoints =
        obj
        ->Dict.get("extensionPoints")
        ->Option.flatMap(JSON.Decode.array)
        ->Option.getOr([])
        ->Array.filterMap(ep =>
          ep
          ->JSON.Decode.object
          ->Option.flatMap(epo =>
            switch (epo->strOf("name"), epo->strOf("eventTopic")) {
            | (Some(name), Some(eventTopic)) =>
              Some(
                (
                  {
                    name,
                    commandTopic: epo->strOf("commandTopic")->Option.getOr(""),
                    eventTopic,
                  }: Reventless.Plugin.extensionPointDefinition
                ),
              )
            | _ => None
            }
          )
        )
      Some({
        id,
        status,
        eventCollector: obj->strOf("eventCollector")->Option.getOr(""),
        extensions,
        extensionPoints,
        dcbEventLog,
      })
    | _ => None
    }
  }

// A pluginDefinition viewed as a projection (the manage logic reads only the
// shared subset; `status` is never read for the acting plugin). Array/option
// fields are js_nullable-normalized — the definition may come from a plain
// JSON.parse of pluginDefinition.json.
let projectionOfDefinition = (d: Reventless.Plugin.pluginDefinition): pluginProjection => {
  id: d.id,
  status: "",
  eventCollector: d.eventCollector,
  extensions: d.extensions,
  extensionPoints: d.extensionPoints,
  dcbEventLog: d.dcbEventLog->jsOption,
}

// ── Cross-plugin SNS subscription manager ───────────────────────────────────
// When DoConnectPlugin / DoDisconnectPlugin fires on the admin EP mapping, scan
// the Plugin RM for currently-Connected peers and wire (or tear down) SNS
// subscriptions between this plugin's EventCollector queue and peer plugins'
// EP/DCB event topics — in both directions. subscribeQueueToTopic is idempotent
// (lists existing subscriptions first); unsubscribeQueueFromTopic is
// best-effort. Failures are logged but do not throw — admin's RM projection
// still proceeds and cold-start reconciliation re-attempts missed work.

type action = [#connect | #disconnect]

let pluginNameOfId = (id: string): string => id->String.split("@")->Array.get(0)->Option.getOr("")

let trySubscribe = async (queueArn: string, topicArn: string, label: string) =>
  if queueArn != "" && topicArn != "" {
    try {
      let _ = await AwsSdk.SNS_Helpers.subscribeQueueToTopic(queueArn, topicArn)
      logInfo(`subscribed ${label}: ${topicArn} -> ${queueArn}`, {comp: "manageSubscriptions"})
    } catch {
    | exn =>
      logError(
        `subscribe failed ${label}: ${topicArn} -> ${queueArn}`,
        {comp: "manageSubscriptions", detail: exnMessage(exn)},
      )
    }
  }

let tryUnsubscribe = async (queueArn: string, topicArn: string, label: string) =>
  if queueArn != "" && topicArn != "" {
    try {
      let _ = await AwsSdk.SNS_Helpers.unsubscribeQueueFromTopic(queueArn, topicArn)
      logInfo(`unsubscribed ${label}: ${topicArn} -> ${queueArn}`, {comp: "manageSubscriptions"})
    } catch {
    | exn =>
      logError(
        `unsubscribe failed ${label}: ${topicArn} -> ${queueArn}`,
        {comp: "manageSubscriptions", detail: exnMessage(exn)},
      )
    }
  }

let connectedFilter: array<Reventless.QueryEngine.Filter.config> = [
  ("status", Reventless.QueryEngine.Filter.Contains, Reventless.QueryEngine.String("Connected")),
]

let scanConnectedPeers = async (tableName: string, excludeId: string): array<pluginProjection> => {
  let rows = await scanByTableName(tableName, connectedFilter, 1000)
  rows->Array.filterMap(projectPluginRow)->Array.filter(state => state.id != excludeId)
}

let makeManageSubscriptions = (tableName: string): option<
  (pluginProjection, action) => promise<unit>,
> =>
  tableName == "" || tableName == "NOT_AVAILABLE"
    ? None
    : Some(
        async (pluginDef, action) => {
          let isConnect = action == #connect
          let op = isConnect ? trySubscribe : tryUnsubscribe
          let peers = await scanConnectedPeers(tableName, pluginDef.id)
          // Subscriptions are wired between SNS topics and SQS queues owned per
          // PLUGIN NAME, not per version (EC queue, EP event topics, and DCB
          // topic ARNs live in the plugin's stack, stable across upgrades).
          // When a superseded version is Retired and its row transitions to
          // Disconnected, this hook fires with #disconnect — but if a newer
          // version of the same plugin is still Connected, the subscriptions
          // are still in use; tearing them down would silently break
          // cross-plugin event flow for the live version. Skip in that case.
          let skip = if isConnect {
            false
          } else {
            let myName = pluginNameOfId(pluginDef.id)
            switch peers->Array.find(p => pluginNameOfId(p.id) == myName) {
            | Some(sibling) =>
              logInfo(
                `disconnect skipped for ${pluginDef.id}: sibling version ${sibling.id} still Connected and shares the same EC queue / EP topics`,
                {comp: "manageSubscriptions"},
              )
              true
            | None => false
            }
          }
          if !skip {
            // This plugin's extensions: peer EP topic → this EC queue.
            for i in 0 to pluginDef.extensions->Array.length - 1 {
              let ext = pluginDef.extensions->Array.getUnsafe(i)
              for j in 0 to peers->Array.length - 1 {
                let peer = peers->Array.getUnsafe(j)
                switch peer.extensionPoints->Array.find(ep => ep.name == ext.extensionPointName) {
                | Some(peerEp) =>
                  await op(
                    pluginDef.eventCollector,
                    peerEp.eventTopic,
                    `${ext.extensionPointName} -> ${pluginDef.id}`,
                  )
                | None => ()
                }
              }
            }
            // This plugin's EPs: this EP topic → peer EC queues.
            for i in 0 to pluginDef.extensionPoints->Array.length - 1 {
              let ep = pluginDef.extensionPoints->Array.getUnsafe(i)
              for j in 0 to peers->Array.length - 1 {
                let peer = peers->Array.getUnsafe(j)
                switch peer.extensions->Array.find(e => e.extensionPointName == ep.name) {
                | Some(_) => await op(peer.eventCollector, ep.eventTopic, `${ep.name} -> ${peer.id}`)
                | None => ()
                }
              }
            }
            // DCB sources this plugin's extensions consume: owning peer's DCB
            // EventTopic → this EC queue.
            for i in 0 to pluginDef.extensions->Array.length - 1 {
              let ext = pluginDef.extensions->Array.getUnsafe(i)
              for j in 0 to ext.dcbSources->Array.length - 1 {
                let dcbSourceName = ext.dcbSources->Array.getUnsafe(j)
                switch peers->Array.find(p =>
                  switch p.dcbEventLog {
                  | Some(l) => l.name == dcbSourceName
                  | None => false
                  }
                ) {
                | Some(peer) =>
                  switch peer.dcbEventLog {
                  | Some(l) =>
                    await op(
                      pluginDef.eventCollector,
                      l.eventTopicArn,
                      `dcb ${dcbSourceName} -> ${pluginDef.id}`,
                    )
                  | None => ()
                  }
                | None => ()
                }
              }
            }
            // If THIS plugin has a DCB EventLog: its topic → each consuming
            // peer's EC queue.
            switch pluginDef.dcbEventLog {
            | Some(myDcb) =>
              for j in 0 to peers->Array.length - 1 {
                let peer = peers->Array.getUnsafe(j)
                let consuming =
                  peer.extensions->Array.some(e => e.dcbSources->Array.includes(myDcb.name))
                if consuming {
                  await op(
                    peer.eventCollector,
                    myDcb.eventTopicArn,
                    `dcb ${myDcb.name} -> ${peer.id}`,
                  )
                }
              }
            | None => ()
            }
          }
        },
      )

// The definition-typed view the admin EP functor expects
// (PluginExtensionPoint_Plugin.Make's `manageSubscriptions` hook).
let manageForDefinition = (
  manage: option<(pluginProjection, action) => promise<unit>>,
): option<(Reventless.Plugin.pluginDefinition, action) => promise<unit>> =>
  manage->Option.map(m => (d, a) => m(projectionOfDefinition(d), a))

// Cold-start reconciliation — scan the Plugin RM for every Connected plugin and
// rerun manageSubscriptions(p, #connect) for each. Idempotent at the SNS level;
// catches subscriptions lost out-of-band. Awaited by the shell inside the same
// invocation that initialised the Lambda (a floating promise would freeze with
// the runtime between invocations).
let reconcileSubscriptionsOnce = async (
  tableName: string,
  manage: option<(pluginProjection, action) => promise<unit>>,
): unit =>
  switch manage {
  | Some(manage) if tableName != "" && tableName != "NOT_AVAILABLE" =>
    try {
      let rows = await scanByTableName(tableName, connectedFilter, 1000)
      for i in 0 to rows->Array.length - 1 {
        switch projectPluginRow(rows->Array.getUnsafe(i)) {
        | Some(state) =>
          try await manage(state, #connect) catch {
          | exn =>
            logWarn(
              "manageSubscriptions failed",
              {comp: "reconcileSubscriptions", detail: exnMessage(exn)},
            )
          }
        | None => ()
        }
      }
    } catch {
    | exn => logWarn("scan failed", {comp: "reconcileSubscriptions", detail: exnMessage(exn)})
    }
  | _ => ()
  }

// ── Operations the shell threads into the (untyped) functor applications ────

// Stack name, not the function name — the disconnect schedule's EventBridge
// rule prefix must be stable across deploys and unique per stack;
// AWS_LAMBDA_FUNCTION_NAME carries a content hash. PluginExtensionPointEntryPoint
// instantiates the same admin EP module and must derive this identically.
let environment = NodeProcess.env->Dict.get("Environment")->Option.getOr("unknown")

// Only what the admin EP mapping's callHandler needs: sendMessageToChannel for
// ForwardCommand.
let runtimeOps: ReventlessCore.PluginRuntimeOperations.operations = {
  messagePublish: {sendMessageToChannel: Util_PluginMessage_Runtime.sendMessage},
}

let invalidNameChars = %re("/[^.\-_a-zA-Z0-9]/g")
let resourceNaming: ReventlessInfra.ResourceNaming.operations = {
  validateName: n => n->String.replaceRegExp(invalidNameChars, "_"),
  urnName: arn =>
    arn->String.split(":")->Array.get(5)->Option.filter(s => s != "")->Option.getOr("unknown"),
}

let makeQueryEngine = (pluginReadModelTableName: string): Reventless.QueryEngine.operations => {
  scan: (~readModelName as _, ~filterConfigs, ~limit) =>
    scanByTableName(pluginReadModelTableName, filterConfigs, limit),
  query: async (
    ~readModelName as _,
    ~key as _=?,
    ~id as _,
    ~subIdConfig as _=?,
    ~filterConfigs as _=?,
    ~ascending as _=?,
    ~limit as _=?,
  ) => JsError.throwWithMessage("QueryEngine.query not available in bundled Plugin EventCollector"),
}

let makeScheduler = (schedulerRoleArn: string): ReventlessCore.Scheduler.operations => {
  createSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.createSchedule(
    ~roleArn=schedulerRoleArn,
  ),
  deleteSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.deleteSchedule,
}

let makeCommandTopicResources = (config: handlerConfig): array<
  ReventlessInfra.Adapter.resolvedResource,
> =>
  config.schedulerQueueArn == ""
    ? []
    : [
        {
          name: config.schedulerQueueName,
          id: config.schedulerQueueName,
          urn: config.schedulerQueueArn,
          service: "unknown",
          resourceInfo: ReventlessInfra.Adapter.NoInfo,
          role: "",
          region: "",
          resourceType: "",
          configuration: Dict.make(),
          tags: Dict.make(),
        },
      ]

let makePublishToEventTopic = (eventTopicArn: string): ReventlessCore.EventTopic.publishJson => {
  let topic: Util_SNS_Runtime.resolvedTopic = {
    name: eventTopicArn,
    id: eventTopicArn,
    arn: eventTopicArn,
  }
  (id, meta, json) => EventTopicPublisher_SNS_Runtime.publish(topic, id, meta, json)
}

let makePublishJsons = (queueUrl: string): ReventlessCore.CommandTopic.publishJsons => {
  let queue: Util_SQS_Runtime.resolvedQueue = {id: queueUrl, name: queueUrl, arn: ""}
  queue->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS_FIFO)
}

// aggregateName → publishJsons, resolving each queue URL via the env-var name
// carried in HANDLER_CONFIG.publishToAggregates.
let buildPublishToAggregates = (map: dict<string>): dict<ReventlessCore.CommandTopic.publishJsons> =>
  map
  ->Dict.toArray
  ->Array.map(((aggName, envVarName)) => (
    aggName,
    makePublishJsons(NodeProcess.env->Dict.get(envVarName)->Option.getOr("")),
  ))
  ->Dict.fromArray

// Per-extension publish dicts, filtered to the extension's declared aggregate /
// read-model names; entries with no env-var mapping or an empty URL are skipped
// (same as the former JS `continue`s).
type extensionDicts = {
  publishToAggregates: dict<ReventlessCore.CommandTopic.publishJsons>,
  publishToReadModels: dict<ReventlessCore.CommandTopic.publishJsons>,
  readModelNamesForSourceName: dict<array<string>>,
}

let extensionPublishDicts = (config: handlerConfig, ext: extensionConfig): extensionDicts => {
  let resolve = (names: array<string>, envVarNames: dict<string>) =>
    names
    ->Array.filterMap(name =>
      envVarNames
      ->Dict.get(name)
      ->Option.flatMap(envVarName => NodeProcess.env->Dict.get(envVarName))
      ->Option.filter(queueUrl => queueUrl != "")
      ->Option.map(queueUrl => (name, makePublishJsons(queueUrl)))
    )
    ->Dict.fromArray
  {
    publishToAggregates: resolve(ext.aggregateNames, config.publishToAggregates),
    publishToReadModels: resolve(ext.readModelNames, config.readModelQueueUrls),
    // Scoped to this extension's EP — Extension_Operations uses this dict to
    // decide which RMs receive each incoming event.
    readModelNamesForSourceName: Dict.fromArray([
      (
        ext.extensionPointName,
        config.readModelNamesForSourceName->Dict.get(ext.extensionPointName)->Option.getOr([]),
      ),
    ]),
  }
}

let warnSkippedExtension = (ext: extensionConfig) =>
  logWarn(
    `extension '${ext.name}' missing module specifier(s); skipping. specModule=${ext.specModule}, mappingsModule=${ext.mappingsModule}, delegateModule=${ext.delegateModule}`,
    {comp: "EventCollectorEntryPoint"},
  )

// ── Asset files (bundled alongside index.mjs in the code archive) ───────────
// pluginDefinition is shipped as a file rather than packed into HANDLER_CONFIG
// (UpdateFunctionConfiguration has a 5120-byte limit; pluginStructure alone blew
// past it). process.cwd() is /var/task in Lambda, so a relative URL resolves
// against the extracted zip.

type url
@new external makeUrl: (string, string) => url = "URL"
@module("node:fs") external readFileSyncUrl: (url, string) => string = "readFileSync"

// pluginDefinition.json is written at deploy time as a stable JSON literal
// matching Reventless.Plugin.pluginDefinitionSchema (PluginRuntime_Builder), so
// the parsed object IS the record shape — cast at the documented contract (the
// AggregateEntryPoint_Ops.asConnectionConfig pattern). js_nullable option
// fields may hold null; consumers normalize via jsOption.
external asPluginDefinition: JSON.t => Reventless.Plugin.pluginDefinition = "%identity"

let loadPluginDefinition = (): Reventless.Plugin.pluginDefinition =>
  try {
    readFileSyncUrl(makeUrl("./pluginDefinition.json", `file://${NodeProcess.cwd()}/`), "utf-8")
    ->JSON.parseOrThrow
    ->asPluginDefinition
  } catch {
  | exn =>
    JsError.throwWithMessage(
      "Failed to load pluginDefinition.json from asset zip: " ++ exnMessage(exn),
    )
  }

// The plugin's UI-fragment manifest — its own asset since the manifest no
// longer rides pluginDefinition (the UiFragmentRegistry slice owns fragment
// state). JSON null (plugins without a UI) and a missing file (older archives)
// both map to None.
let loadUiFragments = (): option<JSON.t> =>
  try {
    switch readFileSyncUrl(makeUrl("./uiFragments.json", `file://${NodeProcess.cwd()}/`), "utf-8")->JSON.parseOrThrow {
    | JSON.Null => None
    | json => Some(json)
    }
  } catch {
  | _ => None
  }

// ── Handler-dict assembly + Plugin_Callback wiring ──────────────────────────
// The shell hands back the handlers its functor applications produced; their
// types are concrete (Extension/ExtensionPoint_Operations outputs), so from
// here on everything is typed again.

type epHandler = {
  aggregateNames: array<string>,
  outgoingHandler: ReventlessCore.Plugin_Callback.jsonEventsHandler,
}
type connectHandler = {
  extensionPointName: string,
  incomingHandler: ReventlessCore.Plugin_Callback.jsonEventsHandler,
}
type extensionHandler = {
  extensionPointName: string,
  aggregateNames: array<string>,
  incomingHandler: ReventlessCore.Plugin_Callback.jsonEventsHandler,
  outgoingHandler: ReventlessCore.Plugin_Callback.jsonEventsHandler,
}

type bundleInput = {
  pluginDefinition: Reventless.Plugin.pluginDefinition,
  queueUrl: string,
  epHandlers: array<epHandler>,
  connectExtensionHandler?: connectHandler,
  extensionHandlers: array<extensionHandler>,
}
type bundle = {
  sqsHandler: (
    PulumiAws.Lambda.CallbackFunction.event,
    PulumiAws.Lambda.context,
  ) => Effect.t<unit, string, unit>,
  comp: string,
}

let pushHandler = (
  d: ReventlessCore.Plugin_Callback.jsonEventsHandlersByService,
  key: string,
  h: ReventlessCore.Plugin_Callback.jsonEventsHandler,
) =>
  switch d->Dict.get(key) {
  | Some(arr) => arr->Array.push(h)
  | None => d->Dict.set(key, [h])
  }

let makeSqsHandlerBundle = (input: bundleInput): bundle => {
  let outgoingExtensionPointEventHandlers: ReventlessCore.Plugin_Callback.jsonEventsHandlersByService = Dict.make()
  input.epHandlers->Array.forEach(eph =>
    eph.aggregateNames->Array.forEach(k =>
      pushHandler(outgoingExtensionPointEventHandlers, k, eph.outgoingHandler)
    )
  )
  let incomingConnectExtensionEventHandlers: ReventlessCore.Plugin_Callback.jsonEventsHandlersByService = switch input.connectExtensionHandler {
  | Some(c) => Dict.fromArray([(c.extensionPointName, [c.incomingHandler])])
  | None => Dict.make()
  }
  let outgoingExtensionEventHandlers: ReventlessCore.Plugin_Callback.jsonEventsHandlersByService = Dict.make()
  let incomingExtensionEventHandlers: ReventlessCore.Plugin_Callback.jsonEventsHandlersByService = Dict.make()
  input.extensionHandlers->Array.forEach(eh => {
    eh.aggregateNames->Array.forEach(k =>
      pushHandler(outgoingExtensionEventHandlers, k, eh.outgoingHandler)
    )
    pushHandler(incomingExtensionEventHandlers, eh.extensionPointName, eh.incomingHandler)
  })

  module Callback = ReventlessCore.Plugin_Callback.Make({
    let pluginDefinition = input.pluginDefinition
    let incomingConnectExtensionEventHandlers = incomingConnectExtensionEventHandlers
    let outgoingExtensionPointEventHandlers = outgoingExtensionPointEventHandlers
    let outgoingExtensionEventHandlers = outgoingExtensionEventHandlers
    let incomingExtensionEventHandlers = incomingExtensionEventHandlers
  })

  let queue: Util_SQS_Runtime.resolvedQueue = {
    id: input.queueUrl,
    name: input.queueUrl,
    arn: "",
  }
  {
    sqsHandler: EventCollectorChannel_SQS_Runtime.handleDynamoDbOrSqsEvent(
      queue,
      Callback.handleJsonEvents,
    ),
    // Backs both the admin and every per-plugin EventCollector Lambda, so the
    // comp names the plugin whose events it drains — matching the
    // `Plugin(<id>)` shape Plugin_Callback logs under.
    comp: `Plugin(${input.pluginDefinition.id})`,
  }
}

// ── Exported Lambda handler (dispatch boundary) ─────────────────────────────

let makeHandler = (bundlePromise: promise<bundle>) =>
  async (event: PulumiAws.Lambda.CallbackFunction.event, context: PulumiAws.Lambda.context) => {
    setRequestId(context.awsRequestId)
    let records = event.records
    logDebug(
      `processing ${records->Array.length->Int.toString} record(s)`,
      {comp: "PluginEventCollectorRuntime"},
    )
    let bundle = await bundlePromise
    await runEffect(
      bundle.sqsHandler(event, context),
      {
        correlationId: ?extractMetaField(records, "correlationId"),
        causationId: ?extractMetaField(records, "causationId"),
        comp: bundle.comp,
        timestamp: ?extractSentTimestamp(records),
        retryCount: extractRetryCount(records),
      },
    )
    ""
  }
