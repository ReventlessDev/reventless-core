open Belt.Result

module ReventlessCommandTopic = CommandTopic

let componentType = ComponentType.Aggregate

type outputs = {
  "name": string,
  "commandGenerator": CommandGenerator.outputs,
  "commandTopic": ReventlessSpec.CommandTopic.outputs,
  "eventLog": EventLog.outputs,
  "eventMapper": option<EventMapper.outputs>,
}
type allOutputs = Js.Dict.t<outputs>

type name = string

type t
type component = ReventlessSpec.Component.t<t, outputs>

type addEventMapper = (
  ReventlessSpec.EventTopic.allOutputs,
  ReventlessSpec.QueryEngine.t,
) => outputs

module type T = {
  module Spec: ReventlessSpec.AggregateSpec.T

  let make: (~opts: Pulumi.ComponentResource.Options.t=?, unit) => component

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
    ~opts: option<Pulumi.ComponentResource.Options.t>,
  ) => component = "default"

  @obj
  external makeOutputs: (
    ~name: string,
    ~commandGenerator: CommandGenerator.outputs,
    ~commandTopic: ReventlessSpec.CommandTopic.outputs,
    ~eventLog: EventLog.outputs,
    ~eventMapper: option<EventMapper.outputs>,
  ) => outputs = ""

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
    let commandJson = command->Spec.command_encode->Js.Json.stringify
    let serviceName = Spec.name
    let id = context.id
    Js.log(`Behaviour error ${errorJson} in ${serviceName}(${id}): Command: ${commandJson}`)
    []
  }

  @inline
  let eventName: Message.event'<Spec.Id.t, Spec.event> => string = event' =>
    event'.event
    ->Spec.event_encode
    ->Util.Decco.Json.variantName
    ->Belt.Option.getWithDefault("Could not get event-name!")

  /* TODO: delete me
     [@inline]
     let errorMessage = (id, kind, err) =>
       {j|Aggregate.execCommand($id): $kind Error: |j}
       ++
       err->Util.Error.ofPromise##message;
 */

  @inline
  let logCommand' = (
    idx,
    count,
    reference,
    command': Message.command'<Spec.Id.t, Spec.command>,
  ) => {
    let id = command'.id
    let commandName =
      command'.command
      ->Spec.command_encode
      ->Util.Decco.Json.variantName
      ->Belt.Option.getWithDefault("Could not get command-name")
    let commandStr =
      command'->Message.command'_encode(Spec.Id.t_encode, Spec.command_encode, _)->Js.Json.stringify
    let idx = idx + 1
    Js.log(
      `CommandTopic: handling command ${idx->Belt.Int.toString}/${count->Belt.Int.toString}: ${commandName}(${id->Spec.Id.toString}) ref: ${reference}, complete command: ${commandStr}`,
    )
  }

  let groupTopicItemsById = (
    topicItems: array<ReventlessCommandTopic.topicItem<Message.command'<Spec.Id.t, Spec.command>>>,
  ) => {
    let ids = topicItems->Belt.Array.map(({command}) => command.id)
    ids
    ->Belt.Set.fromArray(~id=module(Belt.Id.MakeComparable(Spec.Id)))
    ->Belt.Set.toArray
    ->Belt.Array.map(id => (id, topicItems->Belt.Array.keep(({command}) => command.id == id)))
  }

  let handleCommands = ((eventLogAppend, eventLogReplay)) => (. allTopicItems) => {
    let apply' = (stateOpt, event) =>
      switch stateOpt {
      | Some(state) => Some(Behaviour.apply(. state, event))
      | None => Some(Behaviour.init(. event))
      }

    let updateState = (stateOpt, events) => events->Belt.Array.reduce(stateOpt, apply')

    let updateMeta = (command': Message.command'<Spec.Id.t, Spec.command>) => {
      ...command'.meta,
      time: Message.nowAsISOString(),
      msgId: Message.uuid(),
    }

    Js.log("starting Aggregate.execCommands")
    allTopicItems
    ->groupTopicItemsById
    ->Belt.Array.map(((id, topicItems)) =>
      eventLogReplay(. id)->Js.Promise2.then(history => {
        let processCommand = (accP, command': Message.command'<Spec.Id.t, Spec.command>) => {
          let runBehaviour = ((stateO, events)) =>
            switch stateO {
            | Some(state) =>
              let generatedEvents = try Behaviour.execute(.
                state,
                command'.command,
                {
                  id: command'.id->Spec.Id.toString,
                  meta: command'.meta,
                },
                errorHandler,
              ) catch {
              | Message.InvalidEvent(event) =>
                Js.log2("Aggregate.processCommand: InvalidEvent", event->Js.Json.stringify)
                []
              }
              Ok((
                updateState(stateO, generatedEvents),
                Belt.Array.concat(events, [(generatedEvents, command'->updateMeta)]),
              ))->Js.Promise.resolve
            | None =>
              let generatedEvents = Behaviour.create(.
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
              ))->Js.Promise.resolve
            }

          accP->Js.Promise2.then(
            x =>
              switch x {
              | Ok(acc) => runBehaviour(acc)
              | Error(_) as error => error->Js.Promise.resolve
              },
          )
        }

        Js.log(`finished eventLogReplay for id ${id->Spec.Id.toString}`)
        let _ =
          topicItems->Belt.Array.mapWithIndex(
            (idx, {reference, command}) =>
              logCommand'(idx, topicItems->Belt.Array.length, reference, command),
          )
        let (references, commands') =
          // TODO: handle finer granular references
          topicItems
          ->Belt.Array.map(({reference, command}) => (reference, command))
          ->Belt.Array.unzip
        commands'
        ->Belt.Array.reduce(
          Ok((updateState(None, history), []))->Js.Promise.resolve,
          processCommand,
        )
        ->Js.Promise2.then(
          x =>
            switch x {
            | Ok((_, generatedEventsWithMeta)) =>
              generatedEventsWithMeta
              ->Belt.Array.map(
                ((events, meta)) => events->Belt.Array.map(event => {Message.id, meta, event}),
              )
              ->Belt.Array.concatMany
              ->Js.Promise.resolve
            | Error(error) => Js.Exn.raiseError(error)
            },
        )
        ->Js.Promise2.then(
          x =>
            switch x {
            | [] =>
              {
                Js.log(`Aggregate.handleCommands(${id->Spec.Id.toString}): no Event generated`)
                references->Belt.Array.map(reference => Ok(reference))
              }->Js.Promise.resolve
            | generatedEvents' =>
              let eventCount = generatedEvents'->Belt.Array.length
              Js.log2(
                `Aggregate.handleCommands(${id->Spec.Id.toString}): ${eventCount->Belt.Int.toString} Event(s) generated:`,
                generatedEvents'->Belt.Array.map(event' => event'->eventName),
              )
              eventLogAppend(. history->Belt.Array.length, id, generatedEvents')
              ->Js.Promise2.then(
                result =>
                  switch result {
                  | Ok(_) => references->Belt.Array.map(reference => Ok(reference))
                  | Error(_) => references->Belt.Array.map(reference => Error(reference))
                  }->Js.Promise.resolve,
              )
              ->Js.Promise2.then(
                results => {
                  Js.log(`finished eventLogAppend for id ${id->Spec.Id.toString}`)
                  results->Js.Promise.resolve
                },
              )
            },
        )
      })
    )
    ->Js.Promise.all
    ->Js.Promise2.then(results => results->Belt.Array.concatMany->Js.Promise.resolve)
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
              (),
            ),
          )
        : None
    let outputs = component->Component.extractOutputs
    makeOutputs(
      ~name=outputs["name"],
      ~commandGenerator=outputs["commandGenerator"],
      ~commandTopic=outputs["commandTopic"],
      ~eventLog=outputs["eventLog"],
      ~eventMapper=eventMapper->Belt.Option.map(Component.extractOutputs),
    )
  }

  let construct = (self, name) => {
    let opts = Pulumi.ComponentResource.Options.make(~parent=self->Component.toPulumiResource, ())

    let childName = name->ComponentType.name(componentType)

    let eventLog = EventLog.make(~name=childName, ~opts, ())

    let handleCommands = handleCommands((eventLog->EventLog.append, eventLog->EventLog.replay))

    let commandTopic = CommandTopic.make(
      ~name=childName,
      ~commandsHandler=handleCommands,
      ~opts,
      (),
    )

    let commandGenerator = CommandGenerator.make(
      ~name=childName,
      ~publish=commandTopic->CommandTopic.publish,
      ~opts,
      (),
    )

    self->setPublishJsons(commandTopic->CommandTopic.publishJsons)
    self->setAddEventMapper(self->addEventMapperFn(~opts))

    self->setOutputs(
      makeOutputs(
        ~name,
        ~commandGenerator=commandGenerator->Component.extractOutputs,
        ~commandTopic=commandTopic->Component.extractOutputs,
        ~eventLog=eventLog->Component.extractOutputs,
        ~eventMapper=None,
      ),
    )
  }

  let make = (~opts=?, _) =>
    make(~componentType=componentType->ComponentType.toString, ~name=Spec.name, ~construct, ~opts)
}
