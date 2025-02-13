module type Ops = {
  module Spec: ReventlessSpec.Aggregate.Spec
  module EventLog: EventLog.T with module Spec.Id = Spec.Id and type Spec.event = Spec.event
  let eventLog: EventLog.operations
}

module type T = {
  module Spec: ReventlessSpec.Aggregate.Spec
  let handleCommands: array<
    CommandTopic.topicItem<Reventless.Message.command'<Spec.Id.t, Spec.command>>,
  > => promise<array<result<string, string>>>
}

module Make = (
  Spec: ReventlessSpec.Aggregate.Spec,
  Behaviour: Behaviour.T with module Spec := Spec,
  Ops: Ops with module Spec = Spec,
): (T with module Spec = Spec) => {
  module Spec = Spec

  let errorHandler = (error, command, context: Message.context) => {
    let errorJson = error->Spec.error_encode->Js.Json.stringify
    let commandJsonStr = command->Spec.command_encode->Js.Json.stringify
    let serviceName = Spec.name
    let id = context.id
    Logger.error(
      ~loc=__LOC__,
      `Behaviour error ${errorJson} in ${serviceName}(${id}): Command: `,
      commandJsonStr,
    )
    []
  }

  @inline
  let eventName: Message.event'<Spec.Id.t, Spec.event> => string = event' =>
    event'.event
    ->Spec.event_encode
    ->Message.variantNameOfJson

  let groupTopicItemsById = (
    topicItems: array<CommandTopic.topicItem<Message.command'<'id, 'command>>>,
  ) => {
    // FIXME: rethink usage of Set & Belt structures -> optimize
    let ids = topicItems->Belt.Array.map(({command}) => command.id->Spec.Id.toString)
    ids
    ->Belt.Set.String.fromArray
    ->Belt.Set.String.toArray
    ->Belt.Array.map(id => (
      id->Spec.Id.makeFromString,
      topicItems->Belt.Array.keep(({command}) => command.id == id->Spec.Id.makeFromString),
    ))
  }

  let apply' = (stateOpt, event) =>
    switch stateOpt {
    | Some(state) => Some(Behaviour.apply(state, event))
    | None => Some(Behaviour.init(event))
    }

  let updateState = (stateOpt, events) => events->Belt.Array.reduce(stateOpt, apply')

  let updateMeta = (command': Message.command'<'id, 'command>) => {
    ...command'.meta,
    time: Message.nowAsISOString(),
    msgId: Message.uuid(),
  }

  let handleCommands = async allTopicItems => {
    Logger.debug(~loc=__LOC__, "starting", "Aggregate.execCommands")
    let results =
      await allTopicItems
      ->groupTopicItemsById
      ->Belt.Array.map(async ((id, topicItems)) => {
        let history = await Ops.eventLog.replay(id)
        let processCommand = async (accP, command': Message.command'<Spec.Id.t, Spec.command>) => {
          let runBehaviour = ((stateO, events)) =>
            switch stateO {
            | Some(state) =>
              let generatedEvents = try Behaviour.execute(
                state,
                command'.command,
                {
                  id: command'.id->Spec.Id.toString,
                  meta: command'.meta,
                },
                errorHandler,
              ) catch {
              | Message.InvalidEvent(event) =>
                Logger.error(~loc=__LOC__, "Behaviour.execute: InvalidEvent", event)
                []
              }
              Ok((
                updateState(stateO, generatedEvents),
                Belt.Array.concat(events, [(generatedEvents, command'->updateMeta)]),
              ))
            | None =>
              let generatedEvents = Behaviour.create(
                command'.command,
                {
                  id: command'.id->Spec.Id.toString,
                  meta: command'.meta,
                },
                errorHandler,
              )
              Ok((
                updateState(None, generatedEvents),
                Belt.Array.concat(events, [(generatedEvents, command'->updateMeta)]),
              ))
            }

          switch await accP {
          | Ok(acc) => runBehaviour(acc)
          | Error(_) as error => error
          }
        }

        Logger.debug(~loc=__LOC__, "finished eventLogReplay for id", id)

        // TOREVIEW: should we use Logger.debug or just some minimal data here?
        //    also: do we need the additional info of Message.command'
        //            (compared to Spec.command)
        topicItems
        ->Belt.Array.map(({command}) =>
          command->Message.commandJsonOfCommand'(
            ~idToString=Spec.Id.toString,
            ~commandEncode=Spec.command_encode,
          )
        )
        ->Logger.logCmdJsons(~loc=__LOC__, "Handling command")

        let (references, commands') =
          // TODO: handle finer granular references
          topicItems
          ->Belt.Array.map(({reference, command}) => (reference, command))
          ->Belt.Array.unzip
        let result =
          await commands'->Belt.Array.reduce(
            Ok((updateState(None, history), []))->Js.Promise.resolve,
            processCommand,
          )
        let events = switch result {
        | Ok((_, generatedEventsWithMeta)) =>
          generatedEventsWithMeta
          ->Belt.Array.map(((events, meta)) =>
            events->Belt.Array.map(event => {Message.id, meta, event})
          )
          ->Belt.Array.concatMany
        | Error(error) => Js.Exn.raiseError(error)
        }
        switch events {
        | [] => {
            Logger.debug(
              ~loc=__LOC__,
              `handleCommands(${id->Spec.Id.toString})`,
              "no Event generated",
            )
            references->Belt.Array.map(reference => Ok(reference))
          }
        | generatedEvents' =>
          let eventCount = generatedEvents'->Belt.Array.length->Belt.Int.toString
          Logger.debug(
            `Aggregate.handleCommands(${id->Spec.Id.toString}): ${eventCount} Event(s) generated:`,
            generatedEvents'->Belt.Array.map(event' => event'->eventName),
          )
          switch await Ops.eventLog.append(history->Belt.Array.length, id, generatedEvents') {
          | Ok(_) =>
            Logger.debug(~loc=__LOC__, "finished eventLogAppend for id", id->Spec.Id.toString)
            references->Belt.Array.map(reference => Ok(reference))
          | Error(_) =>
            Logger.error(~loc=__LOC__, "failed eventLogAppend for id", id->Spec.Id.toString)
            references->Belt.Array.map(reference => Error(reference))
          }
        }
      })
      ->Js.Promise.all
    results->Belt.Array.concatMany
  }
}
