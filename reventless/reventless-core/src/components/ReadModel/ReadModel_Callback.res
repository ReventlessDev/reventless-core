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

  let handleJsonEvents: EventCollector.jsonEventsHandler = stream =>
    stream
    ->Stream.mapEffect(json =>
      Effect.sync(() => {
        let sourceName = (json->Message.decode(Reventless.Message.contextSchema)).meta.service
        (sourceName, json->EventProjector.map(~sourceName=Some(sourceName)))
      })
      ->Effect.tap(((sourceName, _)) =>
        Effect.logInfo(
          `ReadModel ${ReadModelSpec.name}: handling event from ${sourceName}: ${json->JSON.stringify}`,
        )
      )
      ->Effect.map(((_, actions)) => actions)
    )
    ->Stream.flatMap(actions => Stream.fromIterable(actions))
    ->Stream.runForEach(action =>
      Effect.promise(() =>
        Projection.handleAction(action, Spec.operations, ReadModelSpec.subIdConfig)
      )->Effect.map(_ => ())
    )
}
