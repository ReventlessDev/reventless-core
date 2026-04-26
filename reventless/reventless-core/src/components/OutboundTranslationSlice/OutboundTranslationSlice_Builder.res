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
  module Make = (Spec: Reventless.OutboundTranslationSlice.MergedSpec): (
    OutboundTranslationSlice.T with module Spec = Spec
  ) => {
    module Spec = Spec
    type component = OutboundTranslationSlice.component

    module Callback = OutboundTranslationSlice_Callback.Make(Spec)

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

    let construct = (~dcbEventLog: DcbEventLog.component, ~publishJsons, self, _name) => {
      let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

      let queryDb = SpecificQueryDb.make(~api=Api.api(), ~apiRole=Api.apiRole(), ~opts)

      let dcbEventTopicOutputs: EventTopic.outputs = (dcbEventLog->Component.outputs).eventTopic
      let allEventTopics = Dict.fromArray([(Spec.name, dcbEventTopicOutputs)])

      // Resolve publishJsons so it's available for Phase 2
      let publishJsonsRef: ref<option<ReventlessInfra.CommandTopic.publishJsons>> = ref(None)
      let _ = publishJsons->Pulumi.Output.apply(pj => {
        publishJsonsRef := Some(pj)
      })

      let eventCollector =
        queryDb
        ->Component.operations
        ->Pulumi.Output.apply(queryDbOps => {
          let ec = SpecificEventCollector.make(~name=Spec.name, ~eventTopics=allEventTopics, ~opts)

          let jsonEventsHandler: EventCollector.jsonEventsHandler = stream =>
            stream
            ->Stream.mapEffect(json =>
              Effect.sync(
                () => {
                  let (eventType, dataDict) = json->Message.splitMessage
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
                  // Phase 2: translate pending items
                  switch publishJsonsRef.contents {
                  | Some(pj) => await Callback.phase2(pj)
                  | None =>
                    Console.error(
                      `OutboundTranslationSlice(${Spec.name}): publishJsons not yet resolved`,
                    )
                  }
                  // Sync TODO state to QueryDb for observability
                  await syncToQueryDb(queryDbOps)
                },
              )
            )

          let handler = SpecificEventCollector.makeHandler(~eventCollector=ec, ~jsonEventsHandler)
          let resources = (queryDb->Component.outputs).resources
          ec->EventCollectorRuntimeBuilder.forEventCollector(
            ~handler,
            ~eventTopics=allEventTopics,
            ~resources,
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

    let make = (~dcbEventLog, ~publishJsons, ~opts=?): OutboundTranslationSlice.component =>
      Component.make(
        ~componentType=OutboundTranslationSlice.componentType->ComponentType.toString,
        ~name=Spec.name,
        ~construct=construct(~dcbEventLog, ~publishJsons, ...),
        ~opts,
      )
  }
}
