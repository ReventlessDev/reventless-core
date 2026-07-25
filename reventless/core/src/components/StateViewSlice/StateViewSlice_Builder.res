// Capture the framework's Projection module before the inner functor arg shadows it.
module FrameworkProjection = Projection

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
    Spec: Reventless.StateViewSlice.Spec,
    Projection: Reventless.StateViewSlice.Projection with module Spec := Spec,
  ): StateViewSlice.T => {
    module Spec = Spec
    module Projection = Projection
    type component = StateViewSlice.component

    module SvQueryDbSpec = {
      module Id = Reventless.Id.String
      let name = Spec.name
      let moduleUrl: string = %raw(`import.meta.url`)
      type state = Spec.state
      let stateSchema = Spec.stateSchema
      let config = Spec.config
      let subIdConfig = Spec.subIdConfig
      let authorization = Spec.authorization
      let visibility = Spec.visibility
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

    let construct = (~dcbEventLog: DcbEventLog.component, ~runtime, self, _name) => {
      let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
      let memorySize = ReventlessInfra.RuntimeHints.resolveMemory(runtime, ~default=1024)
      let timeout = ReventlessInfra.RuntimeHints.resolveTimeout(runtime, ~default=30)

      let queryDb = SpecificQueryDb.make(
        ~api=Api.api(),
        ~apiRole=Api.apiRole(),
        ~owner={kind: ComponentType.StateViewSlice, name: Spec.name},
        ~opts,
      )

      let dcbEventTopicOutputs: EventTopic.outputs = (dcbEventLog->Component.outputs).eventTopic
      let allEventTopics = Dict.fromArray([(Spec.name, dcbEventTopicOutputs)])

      let eventCollector =
        queryDb
        ->Component.operations
        ->Pulumi.Output.apply(queryDbOps => {
          let projectionOps = toProjectionOps(queryDbOps)

          let ec = SpecificEventCollector.make(
            ~name=Spec.name,
            ~eventTopics=allEventTopics,
            ~owner={kind: ComponentType.StateViewSlice, name: Spec.name},
            ~opts,
          )

          let comp = `StateViewSlice(${Spec.name})`

          let jsonEventsHandler: EventCollector.jsonEventsHandler = stream =>
            stream
            ->Stream.runCollect
            ->Effect.flatMap(events => {
              let total = events->Array.length->Int.toString
              events
              ->Array.mapWithIndex((json, i) => {
                let envelopeDict = json->JSON.Decode.object->Option.getOr(Dict.make())
                let rawEvent = envelopeDict->Dict.get("event")->Option.getOr(json)
                // Events arrive as `{id, meta, recordedAt, event}` envelopes
                // (Message.composeEventJson' / ProjectionCheckpoint catch-up).
                // Surface `meta` + `recordedAt` to the projection as `consumed`;
                // fall back defensively so a malformed envelope never drops the event.
                let meta = switch envelopeDict->Dict.get("meta") {
                | Some(m) =>
                  switch m->S.parseJsonOrThrow(Message.metaSchema) {
                  | parsed => parsed
                  | exception _ => Message.generateMeta(~service=Spec.name)
                  }
                | None => Message.generateMeta(~service=Spec.name)
                }
                let recordedAt =
                  envelopeDict
                  ->Dict.get("recordedAt")
                  ->Option.flatMap(JSON.Decode.string)
                  ->Option.getOr("")
                let (eventType, dataDict) = rawEvent->Message.splitMessage
                switch decoder.decode(~eventType, ~data=dataDict) {
                | Some(event) =>
                  let actions =
                    try Projection.project({event, meta, recordedAt})
                    catch {
                    | exn =>
                      let errMsg =
                        exn
                        ->JsExn.fromException
                        ->Option.flatMap(JsExn.message)
                        ->Option.getOr("unknown")
                      EffectLogger.logError(
                        ~comp,
                        `project failed for ${eventType}: ${errMsg}`,
                      )->Effect.runSync
                      []
                    }
                  let idxStr = (i + 1)->Int.toString
                  let actionsStr = LogFormat.actionNames(actions)
                  let eventData = dataDict->JSON.Encode.object
                  let fieldsStr = {
                    let f =
                      dataDict
                      ->Dict.toArray
                      ->Array.map(((k, v)) => `${k}:${v->JSON.stringify}`)
                      ->Array.join(",")
                    f == "" ? "" : `({${f}})`
                  }
                  EffectLogger.logInfo(
                    ~comp,
                    ~detail=eventData,
                    `handling event ${idxStr}/${total}: ${LogFormat.bold(eventType)}${fieldsStr} ${actionsStr}`,
                  )->Effect.runSync
                  actions
                | None => []
                }
              })
              ->Array.flat
              ->Array.reduce(Effect.succeed(), (acc, action) =>
                acc->Effect.flatMap(_ =>
                  Effect.promise(() =>
                    FrameworkProjection.handleAction(~comp, action, projectionOps, Spec.subIdConfig)
                  )->Effect.map(_ => ())
                )
              )
            })

          let handler = SpecificEventCollector.makeHandler(
            ~eventCollector=ec,
            ~jsonEventsHandler,
          )
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

    let make = (
      ~dcbEventLog,
      ~runtime=?,
      ~opts=?,
    ): StateViewSlice.component =>
      Component.make(
        ~componentType=StateViewSlice.componentType->ComponentType.toString,
        ~name=Spec.name,
        ~construct=construct(~dcbEventLog, ~runtime, ...),
        ~opts,
      )
  }
}
