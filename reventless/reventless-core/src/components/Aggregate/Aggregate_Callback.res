module type Ops = {
  module Spec: Reventless.Aggregate.Spec
  module EventLog: EventLog.T with module Spec.Id = Spec.Id and type Spec.event = Spec.event
  let eventLog: EventLog.operations
}

module type T = {
  module Spec: Reventless.Aggregate.Spec
  let handleCommands: CommandTopic.commandsHandler<Message.command'<Spec.Id.t, Spec.command>>
}

module Make = (
  Spec: Reventless.Aggregate.Spec,
  Behavior: Behavior.T with module Spec := Spec,
  Ops: Ops with module Spec = Spec,
): (T with module Spec = Spec) => {
  module Spec = Spec

  // Behavior error callback — logs the error and returns [] (no events generated).
  // Called synchronously by Behavior.execute/create, so uses Effect.runSync for logging.
  let errorHandler = (error, command, context: Message.context) => {
    let errorJson = error->Message.encode(Spec.errorSchema)->JSON.stringify
    let commandJsonStr = command->Message.encode(Spec.commandSchema)->JSON.stringify
    let serviceName = Spec.name
    let id = context.id
    Effect.logError(
      `Behavior error ${errorJson} in ${serviceName}(${id}): Command: ${commandJsonStr}`,
    )->Effect.runSync
    []
  }

  @inline
  let eventName: Message.event'<Spec.Id.t, Spec.event> => string = event' =>
    event'.event
    ->Message.encode(Spec.eventSchema)
    ->Message.variantNameOfJson

  // Collects the incoming command stream into groups keyed by aggregate ID.
  // Returns Effect.t<array<(Id.t, array<topicItem>)>>.
  let groupTopicItemsByIdStream = stream =>
    stream
    ->Stream.runFold(Dict.make(), (
      dict,
      item: CommandTopic.topicItem<Message.command'<Spec.Id.t, Spec.command>>,
    ) => {
      let id = item.command.id->Spec.Id.toString
      let existing = dict->Dict.get(id)->Option.getOr([])
      dict->Dict.set(id, Array.concat(existing, [item]))
      dict
    })
    ->Effect.map(dict =>
      dict->Dict.toArray->Array.map(((id, items)) => (id->Spec.Id.makeFromString, items))
    )

  let apply' = (stateOpt, event) =>
    switch stateOpt {
    | Some(state) => Some(Behavior.apply(state, event))
    | None => Some(Behavior.init(event))
    }

  let updateState = (stateOpt, events) => events->Array.reduce(stateOpt, apply')

  let updateMeta = (command': Message.command'<'id, 'command>) => {
    ...command'.meta,
    time: Message.nowAsISOString(),
    msgId: Message.uuid(),
  }

  // Folds a single command into the running accumulator: (currentState, collectedEvents).
  // Delegates to Behavior.execute (existing aggregate) or Behavior.create (new aggregate).
  // Short-circuits on prior Error — subsequent commands in the batch are skipped.
  let processCommand = (acc, command': Message.command'<Spec.Id.t, Spec.command>) =>
    switch acc {
    | Ok((stateO, events)) =>
      let runBehavior = () =>
        switch stateO {
        | Some(state) =>
          let generatedEvents = try Behavior.execute(
            state,
            command'.command,
            {
              id: command'.id->Spec.Id.toString,
              meta: command'.meta,
            },
            errorHandler,
          ) catch {
          | Message.InvalidEvent(event) =>
            Effect.logError(
              `Behavior.execute: InvalidEvent ${event
                ->JSON.stringifyAny
                ->Option.getOr("")}`,
            )->Effect.runSync
            []
          }
          Ok((
            updateState(stateO, generatedEvents),
            Array.concat(events, [(generatedEvents, command'->updateMeta)]),
          ))
        | None =>
          let generatedEvents = Behavior.create(
            command'.command,
            {
              id: command'.id->Spec.Id.toString,
              meta: command'.meta,
            },
            errorHandler,
          )
          Ok((
            updateState(None, generatedEvents),
            Array.concat(events, [(generatedEvents, command'->updateMeta)]),
          ))
        }
      Effect.succeed(runBehavior())
    | Error(_) as error => Effect.succeed(error)
    }

  // CommandTopic handler — processes a stream of incoming commands:
  //   1. Groups commands by aggregate ID
  //   2. For each aggregate (concurrently):
  //      a. Replays the event log to rebuild current state + sequence number
  //      b. Sequentially folds each command through processCommand
  //      c. Appends generated events to the event log (optimistic concurrency via sequenceNr)
  //   3. Returns Ok(reference) for successful commands, Error(reference) for failures
  let handleCommands: CommandTopic.commandsHandler<
    Message.command'<Spec.Id.t, Spec.command>,
  > = stream =>
    stream
    ->groupTopicItemsByIdStream
    ->Effect.tap(_ => Effect.logInfo("starting Aggregate.execCommands"))
    ->Effect.flatMap(groups =>
      Effect.all(
        groups->Array.map(((id, topicItemsForId)) =>
          Ops.eventLog.replayStream(id)
          ->Stream.runFold((None, 0), ((st, n), ev) => (apply'(st, ev), n + 1))
          ->Effect.tap(_ =>
            Effect.logInfo(`finished eventLogReplayStream for id ${id->Spec.Id.toString}`)
          )
          ->Effect.tap(_ => {
            topicItemsForId
            ->Array.map(
              ({command}) =>
                command->Message.commandJsonOfCommand'(
                  ~idToString=Spec.Id.toString,
                  ~commandSchema=Spec.commandSchema,
                ),
            )
            ->LogFormat.commandJsonsToLogMessages
            ->Array.forEach(msg => Effect.logInfo("Handling command: " ++ msg)->Effect.runSync)
            Effect.succeed()
          })
          ->Effect.flatMap(((initialState, sequenceNr)) => {
            let (references, commands') =
              topicItemsForId
              ->Array.map(({reference, command}) => (reference, command))
              ->Belt.Array.unzip

            commands'
            ->Array.reduce(Effect.succeed(Ok((initialState, []))), (accEffect, command') =>
              accEffect->Effect.flatMap(acc => processCommand(acc, command'))
            )
            ->Effect.flatMap(result => {
              let events = switch result {
              | Ok((_, generatedEventsWithMeta)) =>
                generatedEventsWithMeta
                ->Array.map(((events, meta)) =>
                  events->Array.map(event => {Message.id, meta, event})
                )
                ->Array.flat
              | Error(error) => JsError.throwWithMessage(error)
              }
              switch events {
              | [] =>
                Effect.logInfo(
                  `handleCommands(${id->Spec.Id.toString}): no Event generated`,
                )->Effect.map(_ => references->Array.map(reference => Ok(reference)))
              | generatedEvents' =>
                let eventCount = generatedEvents'->Array.length->Int.toString
                let eventNames =
                  generatedEvents'->Array.map(event' => event'->eventName)->Array.join(", ")
                Effect.logInfo(
                  `Aggregate.handleCommands(${id->Spec.Id.toString}): ${eventCount} Event(s) generated: ${eventNames}`,
                )
                ->Effect.flatMap(_ =>
                  Effect.promise(() => Ops.eventLog.append(sequenceNr, id, generatedEvents'))
                )
                ->Effect.flatMap(appendResult =>
                  switch appendResult {
                  | Ok(_) =>
                    Effect.logInfo(
                      `finished eventLogAppend for id ${id->Spec.Id.toString}`,
                    )->Effect.map(_ => references->Array.map(reference => Ok(reference)))
                  | Error(_) =>
                    Effect.logError(
                      `failed eventLogAppend for id ${id->Spec.Id.toString}`,
                    )->Effect.map(_ => references->Array.map(reference => Error(reference)))
                  }
                )
              }
            })
          })
        ),
        {"concurrency": "unbounded"},
      )->Effect.map(Array.flat)
    )
}
