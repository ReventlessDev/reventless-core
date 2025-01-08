open Belt.Result

let componentType = ComponentType.Aggregate

type outputs = {
  name: string,
  commandGenerator: CommandGenerator.outputs,
  commandTopic: ReventlessSpec.CommandTopic.outputs,
  eventLog: EventLog.outputs,
  eventMapper?: EventMapper.outputs,
}
type allOutputs = Js.Dict.t<outputs>

let allEventTopics = allAggregates =>
  Js.Dict.map(aggregate => aggregate.eventLog.eventTopic, allAggregates)

let filterEventTopics = (allAggregates, aggregateNames) =>
  aggregateNames
  ->Belt.Set.String.toArray
  ->Belt.Array.keepMap(aggregateName =>
    allAggregates
    ->Js.Dict.get(aggregateName)
    ->Belt.Option.map(aggregateOutput => (aggregateName, aggregateOutput.eventLog.eventTopic))
  )
  ->Js.Dict.fromArray

type name = string

type t
type component = ReventlessSpec.Component.t<t, outputs>

type addEventMapper = (
  ReventlessSpec.EventTopic.allOutputs,
  ReventlessSpec.QueryEngine.t,
) => outputs

module type T = {
  module Spec: ReventlessSpec.AggregateSpec.T

  let make: (~opts: Pulumi.ComponentResource.options=?) => component

  let publishJsons: component => ReventlessSpec.CommandTopic.publishJsons
  let addEventMapper: component => addEventMapper
}

module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.AggregateSpec.T,
  Behaviour: Behaviour.T with module Spec := Spec,
  EventMappings: EventMapper.Mappings with module Target := Spec,
  CommandGeneratorResolvers: CommandGenerator.Adapter.Resolvers with type api := Config.api,
  CommandTopicConnector: CommandTopic.Adapter.Connector,
  EventLogStorage: EventLog.Adapter.Storage,
  EventTopicPublisher: EventTopic.Adapter.Publisher,
  EventCollectorConnector: EventCollector.Adapter.Connector,
): (T with module Spec = Spec) => {
  module Spec = Spec

  type constructed
  type construct = (component, string) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component = "default"

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  @set
  external setPublishJsons: (component, ReventlessSpec.CommandTopic.publishJsons) => unit =
    "publishJsons"
  @get
  external publishJsons: component => ReventlessSpec.CommandTopic.publishJsons = "publishJsons"

  @set
  external setAddEventMapper: (component, addEventMapper) => unit = "addEventMapper"
  @get
  external addEventMapper: component => addEventMapper = "addEventMapper"

  module CommandGenerator = CommandGenerator.Make(
    Config,
    Spec,
    Behaviour,
    CommandGeneratorResolvers,
  )
  module CommandTopic = CommandTopic.Make(Spec, CommandTopicConnector)
  module EventLog = EventLog.Make(Spec, EventLogStorage, EventTopicPublisher)

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

  /* TODO: delete me
     [@inline]
     let errorMessage = (id, kind, err) =>
       {j|Aggregate.execCommand($id): $kind Error: |j}
       ++
       err->Util.Error.ofPromise##message;
 */

  let groupTopicItemsById = (
    topicItems: array<CommandTopic_Runtime.topicItem<Message.command'<Spec.Id.t, Spec.command>>>,
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

  let handleCommands = ((
    eventLogAppend: EventLogCommon.append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>,
    eventLogReplay,
  )) =>
    async allTopicItems => {
      let apply' = (stateOpt, event) =>
        switch stateOpt {
        | Some(state) => Some(Behaviour.apply(state, event))
        | None => Some(Behaviour.init(event))
        }

      let updateState = (stateOpt, events) => events->Belt.Array.reduce(stateOpt, apply')

      let updateMeta = (command': Message.command'<Spec.Id.t, Spec.command>) => {
        ...command'.meta,
        time: Message.nowAsISOString(),
        msgId: Message.uuid(),
      }

      Logger.debug(~loc=__LOC__, "starting", "Aggregate.execCommands")
      let results =
        await allTopicItems
        ->groupTopicItemsById
        ->Belt.Array.map(async ((id, topicItems)) => {
          let history = await eventLogReplay(id)
          let processCommand = async (
            accP,
            command': Message.command'<Spec.Id.t, Spec.command>,
          ) => {
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
            switch await eventLogAppend(history->Belt.Array.length, id, generatedEvents') {
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

  let addEventMapperFn = (component, allEventTopics, queryEngine, ~opts) => {
    module EventCollector = EventCollector.Make(EventCollectorConnector)
    module EventMapper = EventMapper.Make(Spec, EventCollector, EventMappings)

    let eventMapper =
      EventMappings.mappings->Belt.Array.length > 0
        ? Some(
            EventMapper.make(
              ~allEventTopics,
              ~queryEngine,
              ~publishJsons=component->publishJsons,
              ~opts,
            ),
          )
        : None
    {
      ...component->Component.extractOutputs,
      eventMapper: ?eventMapper->Belt.Option.map(eventMapper =>
        eventMapper->Component.extractOutputs
      ),
    }
  }

  let construct = (self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

    let childName = name->ComponentType.name(componentType)

    let eventLog = EventLog.make(~name=childName, ~opts)

    let handleCommands = handleCommands((eventLog->EventLog.append, eventLog->EventLog.replay))

    let commandTopic = CommandTopic.make(~name=childName, ~commandsHandler=handleCommands, ~opts)

    let commandGenerator = CommandGenerator.make(
      ~name=childName,
      ~publish=commandTopic->CommandTopic.publish,
      ~opts,
    )

    self->setPublishJsons(commandTopic->CommandTopic.publishJsons)
    self->setAddEventMapper(self->(addEventMapperFn(~opts, ...)))

    self->setOutputs({
      name,
      commandGenerator: commandGenerator->Component.extractOutputs,
      commandTopic: commandTopic->Component.extractOutputs,
      eventLog: eventLog->Component.extractOutputs,
    })
  }

  let make = (~opts=?) =>
    make(~componentType=componentType->ComponentType.toString, ~name=Spec.name, ~construct, ~opts)
}
