// AutomationSlice builder — creates the TODO list QueryDb, EventCollector,
// and wires the event handler (Phase 1 + Phase 2) plus exposes processPending.
//
// Follows the StateViewSlice_Builder pattern for adapter injection.

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
    let api: QueryDbStorage.api
    let apiRole: QueryDbStorage.role
  },
) => {
  let finish = EventCollectorRuntimeBuilder.finish
  module Make = (Spec: Reventless.AutomationSlice.Spec): (
    AutomationSlice.T with type dcbEvent = Spec.DcbEventLogSpec.event and module Spec = Spec
  ) => {
    type dcbEvent = Spec.DcbEventLogSpec.event
    module Spec = Spec
    type dcbEventLogComponent = DcbEventLog.component<DcbEventLog.operations<dcbEvent>>
    type component = AutomationSlice.component

    module Callback = AutomationSlice_Callback.Make(Spec)

    let queryDbName = Spec.name ++ "Todo"

    // QueryDb for TODO list — stores todoRow keyed by string ID
    module TodoQueryDbSpec = {
      module Id = Reventless.Id.String
      let name = queryDbName
      let moduleUrl: string = %raw(`import.meta.url`)
      type state = AutomationSlice_Callback.todoRow
      let stateSchema = AutomationSlice_Callback.todoRowSchema
      let config = Reventless.ReadModel.config()
      let subIdConfig: option<Reventless.ReadModel.subIdConfig<state>> = None
    }

    module SpecificQueryDb = QueryDb_Builder.Make(TodoQueryDbSpec, QueryDbStorage, QueryDbResolvers)
    module SpecificEventCollector = EventCollector_Builder.Make(
      RuntimeEnvironment,
      EventCollectorChannel,
    )

    let syncToQueryDb = async (queryDbOps: SpecificQueryDb.operations) => {
      let items = Callback.todoItems.contents->Dict.toArray
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

    let construct = (~dcbEventLog: dcbEventLogComponent, ~publishJsons, self, _name) => {
      let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

      let queryDb = SpecificQueryDb.make(~api=Api.api, ~apiRole=Api.apiRole, ~opts)

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
                () =>
                  try [json->S.parseJsonOrThrow(Spec.DcbEventLogSpec.eventSchema)] catch {
                  | exn =>
                    Console.log2("AutomationSlice: Failed to decode event:", exn)
                    []
                  },
              )
            )
            ->Stream.flatMap(events => Stream.fromIterable(events))
            ->Stream.runCollect
            ->Effect.flatMap(eventsArr =>
              Effect.promise(
                async () => {
                  // Phase 1: collect/resolve
                  Callback.phase1(eventsArr)
                  // Phase 2: process pending items
                  switch publishJsonsRef.contents {
                  | Some(pj) => await Callback.phase2(pj)
                  | None =>
                    Console.error(`AutomationSlice(${Spec.name}): publishJsons not yet resolved`)
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
          let ops: AutomationSlice.operations = {
            enqueueEvent: ecOps.enqueueEvent,
            processPending: async () => await Callback.phase2(publishJsonsFn),
          }
          ops
        }),
      )

      let outputs: AutomationSlice.outputs = {
        resources: dcbEventTopicOutputs.resources,
        queryDb: queryDb->Component.outputs,
      }
      self->Component.setOutputs(outputs)
    }

    let make = (~dcbEventLog, ~publishJsons, ~opts=?): AutomationSlice.component =>
      Component.make(
        ~componentType=AutomationSlice.componentType->ComponentType.toString,
        ~name=Spec.name,
        ~construct=construct(~dcbEventLog, ~publishJsons, ...),
        ~opts,
      )
  }
}
