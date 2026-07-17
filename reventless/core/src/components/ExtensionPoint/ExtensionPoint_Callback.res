module type Mappings = {
  module Spec: ReventlessInfra.ExtensionPointMapping.Spec
  module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
  let mappings: array<module(Mapping)>
}

module type Spec = {
  let publishToAggregates: dict<CommandTopic.publishJsons>
  let commandTopicResources: array<Adapter.resolvedResource>
  let scheduler: Scheduler.operations
  let queryEngine: Reventless.QueryEngine.operations
  let resourceNaming: ReventlessInfra.ResourceNaming.operations
}

module type T = {
  module MappingSpec: ReventlessInfra.ExtensionPointMapping.Spec
  let handleIncomingCommands: CommandTopic.commandsHandler<
    Message.command'<Reventless.Id.String.t, MappingSpec.command>,
  >
}

module Make = (
  Spec: Spec,
  MappingSpec: ReventlessInfra.ExtensionPointMapping.Spec,
  Mappings: Mappings with module Spec := MappingSpec,
): (T with module MappingSpec = MappingSpec) => {
  module MappingSpec = MappingSpec

  // Runs all registered Mapping modules against the incoming commands, collecting
  // the resulting command actions (publish-to-aggregate or async call).
  let mapIncomingCommands = (topicItems, mappings, scheduler, queryEngine, resourceNaming, queue) =>
    mappings
    ->Array.map((module(Mapping: Mappings.Mapping)) =>
      Mapping.mapIncomingCommands(
        topicItems,
        ScheduleOps.create(~scheduler, ~channelResources=queue, ~resourceNaming),
        ScheduleOps.delete(~scheduler, ~channelResources=queue, ~resourceNaming),
        queryEngine,
      )
    )
    ->Array.flat

  // Executes a single command action: either publishes a command JSON to the target
  // aggregate's CommandTopic, or calls an async handler. Errors are logged and returned
  // as Error(reference) without failing the overall batch.
  let applyCommandAction = action =>
    switch action {
    | ReventlessInfra.ExtensionPointMapping.AbstractPublishCommand(
        aggregateName,
        reference,
        cmdJson,
      ) =>
      Effect.trySync(
        ~catch=err => {
          let errMsg = Util.Error.messageFromUnknown(err, "unknown")
          (Error(reference), `ExtensionPoint: Error on publish command: ${errMsg}`)
        },
        () => {
          let result =
            Spec.publishToAggregates
            ->Dict.get(aggregateName)
            ->Option.map((publishJsons: CommandTopic.publishJsons) => publishJsons([cmdJson]))
            ->Option.mapOr(
              () =>
                JsError.throwWithMessage(
                  `ExtensionPoint.applyCommandAction: Aggregate ${aggregateName} doesn't exist`,
                ),
              x => {() => x},
            )
          let _ = result()
          Ok(reference)
        },
      )
      ->Effect.catchAll(((errorResult, errMsg)) =>
        EffectLogger.logError(~comp="ExtensionPoint", errMsg)->Effect.map(_ => errorResult)
      )
    | AbstractHandleDirective(reference, handler) =>
      Effect.tryPromise(
        ~catch=err => {
          let errMsg = Util.Error.messageFromUnknown(err, "unknown")
          (Error(reference), `ExtensionPoint: Error on handling directive: ${errMsg}`)
        },
        () => handler(),
      )
      ->Effect.map(_ => Ok(reference))
      ->Effect.catchAll(((errorResult, errMsg)) =>
        EffectLogger.logError(~comp="ExtensionPoint", errMsg)->Effect.map(_ => errorResult)
      )
    }

  // CommandTopic handler — collects all incoming commands, maps them through the
  // extension point mappings, then applies each resulting action concurrently.
  let handleIncomingCommands = stream =>
    stream
    ->Stream.runCollect
    ->Effect.flatMap(topicItems => {
      let commandActions =
        topicItems->mapIncomingCommands(
          Mappings.mappings,
          Spec.scheduler,
          Spec.queryEngine,
          Spec.resourceNaming,
          Spec.commandTopicResources,
        )
      Effect.all(
        commandActions->Array.map(applyCommandAction),
        {"concurrency": "unbounded"},
      )
    })
}
