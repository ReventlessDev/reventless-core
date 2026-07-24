// OutboundTranslationSlice builder — creates the TODO list QueryDb, EventCollector,
// and wires the event handler (Phase 1 + Phase 2) plus exposes translatePending.
//
// Follows the AutomationSlice_Builder pattern for adapter injection.

module Make = (
  RuntimeEnvironment: Runtime.Environment,
  QueryDbStorage: QueryDb_Adapter.Storage,
  QueryDbResolvers: QueryDb_Adapter.Resolvers
    with type api = QueryDbStorage.api
    and type role = QueryDbStorage.role,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventCollectorRuntimeBuilder: EventCollectorRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel,
  Api: {
    let api: unit => QueryDbStorage.api
    let apiRole: unit => QueryDbStorage.role
  },
) => {
  let finish = EventCollectorRuntimeBuilder.finish
  module Make = (
    Spec: Reventless.OutboundTranslationSlice.Spec,
    Translation: Reventless.OutboundTranslationSlice.Translation with module Spec := Spec,
  ): OutboundTranslationSlice.T => {
    module Spec = Spec
    module Translation = Translation
    type component = OutboundTranslationSlice.component

    module Callback = OutboundTranslationSlice_Callback.Make(Spec, Translation)

    let queryDbName = Spec.name ++ "Todo"

    // QueryDb for TODO list — stores todoRow keyed by string ID
    module TodoQueryDbSpec = {
      module Id = Reventless.Id.String
      let name = queryDbName
      let moduleUrl: string = %raw(`import.meta.url`)
      type state = OutboundTranslationSlice_Callback.todoRow
      let stateSchema = OutboundTranslationSlice_Callback.todoRowSchema
      let config = Reventless.ReadModel.config()
      let subIdConfig: option<Reventless.ReadModel.subIdConfig<state>> = None
      let authorization: Reventless.Authorization.permission = AllowAuthenticated
      let visibility: Reventless.Visibility.t = Public
    }

    module SpecificQueryDb = QueryDb_Builder.Make(TodoQueryDbSpec, QueryDbStorage, QueryDbResolvers)
    module SpecificEventCollector = EventCollector_Builder.Make(
      RuntimeEnvironment,
      EventCollectorChannel,
    )

    let decoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)

    let syncToQueryDb = async (queryDbOps: SpecificQueryDb.operations) => {
      let items = Callback.todoItems->Dict.toArray
      let _ = await items->Array.reduce(Promise.resolve(), async (prev, (id, row)) => {
        let _ = await prev
        let _ = await queryDbOps.save(
          id->Reventless.Id.String.makeFromString,
          row,
          QueryDb.Overwrite,
          None,
        )
      })
    }

    let construct = (~dcbEventLog: DcbEventLog.component, ~publishJsons, ~runtime, self, _name) => {
      let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
      let memorySize = ReventlessInfra.RuntimeHints.resolveMemory(runtime, ~default=1024)
      let timeout = ReventlessInfra.RuntimeHints.resolveTimeout(runtime, ~default=30)

      let queryDb = SpecificQueryDb.make(
        ~api=Api.api(),
        ~apiRole=Api.apiRole(),
        ~owner={kind: ComponentType.OutboundTranslationSlice, name: Spec.name},
        ~opts,
      )

      let dcbEventTopicOutputs: EventTopic.outputs = (dcbEventLog->Component.outputs).eventTopic
      // Key the topic by the source-name convention AutomationSlice and
      // Dcb_Builder use (`<pluginName>DcbEventLog`) rather than by this slice's
      // own name. No backend routes on the key — local subscribes on
      // `resource.name`, AWS reads `Dict.valuesToArray` — but channel specs are
      // merged with `Dict.assign`, so slice-specific keys make one topic appear
      // once per slice instead of collapsing to a single entry.
      let dcbEventLogName =
        (dcbEventLog->Component.toPulumiResource).name->Option.getOr("") ++ "DcbEventLog"
      let allEventTopics = Dict.fromArray([(dcbEventLogName, dcbEventTopicOutputs)])

      // Build the EventCollector inside an Output.all2 so both `queryDbOps` and
      // `publishJsonsFn` are captured in the same closure. The jsonEventsHandler
      // then has direct access to `publishJsonsFn` — avoids racing a
      // side-effect-only `publishJsons.apply` against the first event arrival
      // (which silently dropped Phase 2 in the AutomationSlice's previous shape).
      let eventCollector =
        (queryDb->Component.operations, publishJsons)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((queryDbOps, publishJsonsFn)) => {
          let ec = SpecificEventCollector.make(
            ~name=Spec.name,
            ~eventTopics=allEventTopics,
            ~owner={kind: ComponentType.OutboundTranslationSlice, name: Spec.name},
            ~opts,
          )

          let jsonEventsHandler: EventCollector.jsonEventsHandler = stream =>
            stream
            ->Stream.mapEffect(json =>
              Effect.sync(
                () => {
                  // Events arrive as `{id, meta, event}` envelopes (see
                  // Message.composeEventJson'). The decoder works on the inner
                  // `event` payload — TAG + fields at the top level — not the
                  // wrapper. Splitting the wrapper yields eventType "Unknown",
                  // which DcbDecode drops without warning.
                  let rawEvent =
                    json
                    ->JSON.Decode.object
                    ->Option.flatMap(d => d->Dict.get("event"))
                    ->Option.getOr(json)
                  let (eventType, dataDict) = rawEvent->Message.splitMessage
                  switch decoder.decode(~eventType, ~data=dataDict) {
                  | Some(event) => [event]
                  | None => []
                  }
                },
              )
            )
            ->Stream.flatMap(events => Stream.fromIterable(events))
            ->Stream.runCollect
            ->Effect.flatMap(eventsArr =>
              Effect.promise(
                async () => {
                  // Phase 1: collect outbound items
                  Callback.phase1(eventsArr)
                  // Sync the post-phase-1 TODO state so consumers awaiting the
                  // originating publishEvent observe Pending rows immediately.
                  await syncToQueryDb(queryDbOps)
                  // Phase 2 must NOT be awaited here. If a translation publishes
                  // an inbound command whose downstream events fan back to this
                  // same topic, awaiting would self-deadlock the bus — same
                  // shape as AutomationSlice. Detach it; errors are logged.
                  let _ =
                    Callback.phase2(publishJsonsFn)
                    ->Promise.then(() => syncToQueryDb(queryDbOps))
                    ->Promise.catch(exn => {
                      let errMsg =
                        exn
                        ->JsExn.fromException
                        ->Option.flatMap(JsExn.message)
                        ->Option.getOr("unknown")
                      EffectLogger.logError(
                        ~comp=`OutboundTranslationSlice(${Spec.name})`,
                        `detached phase 2 error: ${errMsg}`,
                      )->Effect.runSync
                      Promise.resolve()
                    })
                },
              )
            )

          let handler = SpecificEventCollector.makeHandler(~eventCollector=ec, ~jsonEventsHandler)
          let resources = (queryDb->Component.outputs).resources
          ec->EventCollectorRuntimeBuilder.forEventCollector(
            ~handler,
            ~eventTopics=allEventTopics,
            ~resources,
            ~memorySize,
            ~timeout,
          )
          ec
        })

      self->Component.setOperations(
        (eventCollector->Pulumi.Output.flatMap(ec => ec->Component.operations), publishJsons)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((ecOps, publishJsonsFn)) => {
          let ops: OutboundTranslationSlice.operations = {
            enqueueEvent: ecOps.enqueueEvent,
            translatePending: async () => await Callback.phase2(publishJsonsFn),
          }
          ops
        }),
      )

      let outputs: OutboundTranslationSlice.outputs = {
        resources: dcbEventTopicOutputs.resources,
        queryDb: queryDb->Component.outputs,
      }
      self->Component.setOutputs(outputs)
    }

    let make = (
      ~dcbEventLog,
      ~publishJsons,
      ~runtime=?,
      ~opts=?,
    ): OutboundTranslationSlice.component =>
      Component.make(
        ~componentType=OutboundTranslationSlice.componentType->ComponentType.toString,
        ~name=Spec.name,
        ~construct=construct(~dcbEventLog, ~publishJsons, ~runtime, ...),
        ~opts,
      )
  }
}
