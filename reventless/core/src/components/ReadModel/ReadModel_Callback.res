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

  // Each row the events change is logged, and handed to whoever listens.
  let onChange = ViewChange.reporter(~comp, ~view=ReadModelSpec.name, ~stateToJson=state =>
    state->Reventless.Util_Sury.toJson(ReadModelSpec.stateSchema)
  )

  let handleJsonEvents: EventCollector.jsonEventsHandler = stream =>
    stream
    ->Stream.runCollect
    ->Effect.flatMap(events => {
      let total = events->Array.length->Int.toString
      events
      ->Array.mapWithIndex((json, idx) => {
        let context = json->Message.decode(Reventless.Message.contextSchema)
        let sourceName = context.meta.service
        let actions = json->EventProjector.map(~sourceName=Some(sourceName))
        let actionsStr = LogFormat.actionNames(actions)
        let idxStr = (idx + 1)->Int.toString
        EffectLogger.logInfo(
          ~comp,
          ~ids=EffectLogger.idsOf(context.meta, ~entityId=context.id, ~entityType=sourceName),
          ~detail=json,
          `handling event ${idxStr}/${total} from ${sourceName}: ${LogFormat.eventDetail(
              json,
            )} actions:${actionsStr}`,
        )->Effect.runSync
        // The event each action came from, kept for the change it makes: the
        // entity is the aggregate the event was published for.
        let sources = [
          ViewChange.sourceOf(~meta=context.meta, ~entityId=context.id, ~entityType=sourceName, ()),
        ]
        // Rewritten here rather than at the apply below: a trail entry is
        // stamped with this envelope's own time.
        actions->Array.map(
          action => (
            action->Projection.rewriteAction(~at=context.meta.time, ReadModelSpec.stateSchema),
            sources,
          ),
        )
      })
      ->Array.flat
      ->Array.reduce(Effect.succeed(), (acc, (action, sources)) =>
        acc->Effect.flatMap(
          _ => {
            Effect.promise(
              () =>
                Projection.handleAction(
                  ~comp,
                  ~sources,
                  ~onChange,
                  action,
                  Spec.operations,
                  ReadModelSpec.subIdConfig,
                ),
            )->Effect.map(_ => ())
          },
        )
      )
    })
}
