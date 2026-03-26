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
  module Make = (Spec: Reventless.StateViewSlice.Spec): (
    StateViewSlice.T with module Spec = Spec
  ) => {
    module Spec = Spec
    type component = StateViewSlice.component

    module SvQueryDbSpec = {
      module Id = Reventless.Id.String
      let name = Spec.name
      let moduleUrl: string = %raw(`import.meta.url`)
      type state = Spec.state
      let stateSchema = Spec.stateSchema
      let config = Reventless.ReadModel.config()
      let subIdConfig: option<Reventless.ReadModel.subIdConfig<state>> = None
    }

    module SpecificQueryDb = QueryDb_Builder.Make(SvQueryDbSpec, QueryDbStorage, QueryDbResolvers)
    module SpecificEventCollector = EventCollector_Builder.Make(RuntimeEnvironment, EventCollectorChannel)

    let toProjectionOps = (ops: SpecificQueryDb.operations): QueryDb.operations<string, Spec.state> => {
      load: id => ops.load(id->Reventless.Id.String.makeFromString),
      loadStream: id => ops.loadStream(id->Reventless.Id.String.makeFromString),
      save: (id, s, sm, ttl) => ops.save(id->Reventless.Id.String.makeFromString, s, sm, ttl),
      saveBatch: batch =>
        ops.saveBatch(
          batch->Array.map(((id, s, ttl)) => (id->Reventless.Id.String.makeFromString, s, ttl)),
        ),
      count: (id, f, n) => ops.count(id->Reventless.Id.String.makeFromString, f, n),
      delete: (id, sub) => ops.delete(id->Reventless.Id.String.makeFromString, sub),
      deleteBatch: ids =>
        ops.deleteBatch(
          ids->Array.map(((id, sort)) => (id->Reventless.Id.String.makeFromString, sort)),
        ),
    }

    let decoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)

    let construct = (~dcbEventLog: DcbEventLog.component, self, _name) => {
      let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

      let queryDb = SpecificQueryDb.make(~api=Api.api, ~apiRole=Api.apiRole, ~opts)

      let dcbEventTopicOutputs: EventTopic.outputs = (dcbEventLog->Component.outputs).eventTopic
      let allEventTopics = Dict.fromArray([(Spec.name, dcbEventTopicOutputs)])

      let eventCollector =
        queryDb
        ->Component.operations
        ->Pulumi.Output.apply(queryDbOps => {
          let projectionOps = toProjectionOps(queryDbOps)

          let ec = SpecificEventCollector.make(~name=Spec.name, ~eventTopics=allEventTopics, ~opts)

          let jsonEventsHandler: EventCollector.jsonEventsHandler = stream =>
            stream
            ->Stream.mapEffect(json =>
              Effect.sync(() => {
                // Decode raw event JSON to get eventType + data, then decode via consumedEventSchema
                let (eventType, dataDict) = json->Message.splitMessage
                switch decoder.decode(~eventType, ~data=dataDict) {
                | Some(event) =>
                  try Spec.project(event)
                  catch {
                  | exn =>
                    Console.log2("StateViewSlice: Failed to project event:", exn)
                    []
                  }
                | None => [] // Event type not consumed by this view
                }
              })
            )
            ->Stream.flatMap(actions => Stream.fromIterable(actions))
            ->Stream.runForEach(action =>
              Effect.promise(() =>
                Projection.handleAction(action, projectionOps, None)
              )
              ->Effect.map(_ => ())
            )

          let handler = SpecificEventCollector.makeHandler(
            ~eventCollector=ec,
            ~jsonEventsHandler,
          )
          let resources = (queryDb->Component.outputs).resources
          ec->EventCollectorRuntimeBuilder.forEventCollector(
            ~handler,
            ~eventTopics=allEventTopics,
            ~resources,
          )
          ec
        })

      self->Component.setOperations(
        eventCollector
        ->Pulumi.Output.flatMap(ec => ec->Component.operations)
        ->Pulumi.Output.apply(({enqueueEvent}) => {
          let ops: StateViewSlice.operations = {enqueueEvent: enqueueEvent}
          ops
        }),
      )

      let outputs: StateViewSlice.outputs = {
        resources: dcbEventTopicOutputs.resources,
        queryDb: queryDb->Component.outputs,
      }
      self->Component.setOutputs(outputs)
    }

    let make = (~dcbEventLog, ~opts=?): StateViewSlice.component =>
      Component.make(
        ~componentType=StateViewSlice.componentType->ComponentType.toString,
        ~name=Spec.name,
        ~construct=construct(~dcbEventLog, ...),
        ~opts,
      )
  }
}
