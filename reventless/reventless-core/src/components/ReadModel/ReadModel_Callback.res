module type Spec = {
  module ReadModelSpec: Reventless.ReadModel.Spec
  let operations: QueryDb.operations<string, ReadModelSpec.state>
}

module Make = (
  ReadModelSpec: Reventless.ReadModel.Spec,
  Mappings: Reventless.Projection.Mappings with module Target := ReadModelSpec,
  Spec: Spec with module ReadModelSpec = ReadModelSpec,
) => {
  module EventProjector = ProjectionMapper.Make(ReadModelSpec, Mappings)

  let comp = `ReadModel(${ReadModelSpec.name})`

  let handleJsonEvents: EventCollector.jsonEventsHandler = stream =>
    stream
    ->Stream.runCollect
    ->Effect.flatMap(events => {
      let total = events->Array.length->Int.toString
      events
      ->Array.mapWithIndex((json, idx) => {
        let context = json->Message.decode(Reventless.Message.contextSchema)
        let sourceName = context.meta.service
        let eventName = json->Message.eventNameOfEvent'Json
        let (id, _, _) = json->Message.idMetaEventOfEvent'Json
        let actions = json->EventProjector.map(~sourceName=Some(sourceName))
        let actionsStr = LogFormat.actionNames(actions)
        let idxStr = (idx + 1)->Int.toString
        EffectLogger.logInfo(
          ~comp,
          ~detail=json,
          `handling event ${idxStr}/${total} from ${sourceName}: ${LogFormat.eventDetail(
              json,
            )} actions:${actionsStr}`,
        )->Effect.runSync
        actions
      })
      ->Array.flat
      ->Array.reduce(Effect.succeed(), (acc, action) =>
        acc->Effect.flatMap(
          _ =>
            Effect.promise(
              () => Projection.handleAction(action, Spec.operations, ReadModelSpec.subIdConfig),
            )->Effect.map(_ => ()),
        )
      )
    })
}
