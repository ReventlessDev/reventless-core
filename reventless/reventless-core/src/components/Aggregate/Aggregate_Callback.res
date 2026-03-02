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

  let errorHandler = (error, command, context: Message.context) => {
    let errorJson = error->Message.encode(Spec.errorSchema)->JSON.stringify
    let commandJsonStr = command->Message.encode(Spec.commandSchema)->JSON.stringify
    let serviceName = Spec.name
    let id = context.id
    Logger.error(
      ~loc=__LOC__,
      `Behavior error ${errorJson} in ${serviceName}(${id}): Command: `,
      commandJsonStr,
    )
    []
  }

  @inline
  let eventName: Message.event'<Spec.Id.t, Spec.event> => string = event' =>
    event'.event
    ->Message.encode(Spec.eventSchema)
    ->Message.variantNameOfJson

  let groupTopicItemsByIdStream = stream =>
    stream
    ->Stream.runFold(
      Dict.make(),
      (dict, item: CommandTopic.topicItem<Message.command'<Spec.Id.t, Spec.command>>) => {
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

  let handleCommands: CommandTopic.commandsHandler<
    Message.command'<Spec.Id.t, Spec.command>,
  > = stream =>
    stream
    ->groupTopicItemsByIdStream
    ->Effect.flatMap(groups =>
      Effect.promise(async () => {
        Logger.debug(~loc=__LOC__, "starting", "Aggregate.execCommands")
        let results = await groups
        ->Array.map(async ((id, topicItemsForId)) => {
      // Single-pass stream fold: produces both (initialState, sequenceNr) from the event log.
      // sequenceNr replaces history->Array.length as the optimistic concurrency token for append.
      let (initialState, sequenceNr) = await Ops.eventLog.replayStream(id)
        ->Stream.runFold((None, 0), ((st, n), ev) => (apply'(st, ev), n + 1))
        ->Effect.runPromise
      let processCommand = async (accP, command': Message.command'<Spec.Id.t, Spec.command>) => {
        let runBehavior = ((stateO, events)) =>
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
              Logger.error(~loc=__LOC__, "Behavior.execute: InvalidEvent", event)
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

        switch await accP {
        | Ok(acc) => runBehavior(acc)
        | Error(_) as error => error
        }
      }

      Logger.debug(~loc=__LOC__, "finished eventLogReplayStream for id", id)

      // TOREVIEW: should we use Logger.debug or just some minimal data here?
      //    also: do we need the additional info of Message.command'
      //            (compared to Spec.command)
      topicItemsForId
      ->Array.map(({command}) =>
        command->Message.commandJsonOfCommand'(
          ~idToString=Spec.Id.toString,
          ~commandSchema=Spec.commandSchema,
        )
      )
      ->Logger.logCmdJsons(~loc=__LOC__, "Handling command")

      let (references, commands') =
        // TODO: handle finer granular references
        topicItemsForId
        ->Array.map(({reference, command}) => (reference, command))
        ->Belt.Array.unzip
      let result = await commands'->Array.reduce(
        Ok((initialState, []))->Promise.resolve,
        processCommand,
      )
      let events = switch result {
      | Ok((_, generatedEventsWithMeta)) =>
        generatedEventsWithMeta
        ->Array.map(((events, meta)) => events->Array.map(event => {Message.id, meta, event}))
        ->Array.flat
      | Error(error) => JsError.throwWithMessage(error)
      }
      switch events {
      | [] => {
          Logger.debug(
            ~loc=__LOC__,
            `handleCommands(${id->Spec.Id.toString})`,
            "no Event generated",
          )
          references->Array.map(reference => Ok(reference))
        }
      | generatedEvents' =>
        let eventCount = generatedEvents'->Array.length->Int.toString
        Logger.debug(
          `Aggregate.handleCommands(${id->Spec.Id.toString}): ${eventCount} Event(s) generated:`,
          generatedEvents'->Array.map(event' => event'->eventName),
        )
        switch await Ops.eventLog.append(sequenceNr, id, generatedEvents') {
        | Ok(_) =>
          Logger.debug(~loc=__LOC__, "finished eventLogAppend for id", id->Spec.Id.toString)
          references->Array.map(reference => Ok(reference))
        | Error(_) =>
          Logger.error(~loc=__LOC__, "failed eventLogAppend for id", id->Spec.Id.toString)
          references->Array.map(reference => Error(reference))
        }
      }
    })
    ->Promise.all
    results->Array.flat
  })
)
}
