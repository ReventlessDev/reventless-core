open ReventlessSpec.Adapter

let componentType = ComponentType.CommandTopic

exception NotPublishedToConnector(Js.Promise.error)

module type Spec = {
  module Id: ReventlessSpec.Id.T

  @decco
  type command
}

type topicItem<'command> = {
  command: 'command,
  reference: string,
}

type commandsHandler<'command> = (
  . array<topicItem<'command>>,
) => Js.Promise.t<array<Belt.Result.t<string, string>>>

module type T = {
  module Spec: Spec

  type t

  type commandsHandler = commandsHandler<Message.command'<Spec.Id.t, Spec.command>>

  let make: (
    ~name: string,
    ~commandsHandler: commandsHandler,
    ~memorySize: int=?,
    ~timeout: int=?,
    ~opts: Pulumi.ComponentResource.Options.t=?,
    unit,
  ) => ReventlessSpec.Component.t<t, ReventlessSpec.CommandTopic.outputs>

  let publish: ReventlessSpec.Component.t<
    t,
    ReventlessSpec.CommandTopic.outputs,
  > => ReventlessSpec.CommandTopic.publish<Spec.Id.t, Spec.command>
  let publishJsons: ReventlessSpec.Component.t<
    t,
    ReventlessSpec.CommandTopic.outputs,
  > => ReventlessSpec.CommandTopic.publishJsons
}

module Adapter = {
  type connector = {
    resources: array<resource>,
    publish: ReventlessSpec.CommandTopic.publishJsons,
  }
  type connectorMaker = (
    ~name: string,
    ~handleCommands: commandsHandler<Js.Json.t>,
    ~memorySize: int,
    ~timeout: int,
    ~opts: Pulumi.CustomResourceOptions.t,
  ) => connector

  module type Connector = {
    let make: connectorMaker
  }

  type remoteConnector = {remotePublish: ReventlessSpec.CommandTopic.publishJsons}
  type remoteConnectorMaker = ReventlessSpec.CommandTopic.outputs => remoteConnector

  module type RemoteConnector = {
    let make: remoteConnectorMaker
  }
}

module Make = (Spec: Spec, Connector: Adapter.Connector): (T with module Spec = Spec) => {
  module Spec = Spec

  type t

  type commandsHandler = commandsHandler<Message.command'<Spec.Id.t, Spec.command>>

  type constructed
  type construct = (
    ReventlessSpec.Component.t<t, ReventlessSpec.CommandTopic.outputs>,
    string,
    commandsHandler,
  ) => constructed

  type publish = ReventlessSpec.CommandTopic.publish<Spec.Id.t, Spec.command>

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.Options.t>,
    ~commandsHandler: commandsHandler,
  ) => ReventlessSpec.Component.t<t, ReventlessSpec.CommandTopic.outputs> = "default"

  @obj
  external makeOutputs: (~resources: array<resource>) => ReventlessSpec.CommandTopic.outputs = ""

  @send
  external registerOutputs: (
    ReventlessSpec.Component.t<t, ReventlessSpec.CommandTopic.outputs>,
    ReventlessSpec.CommandTopic.outputs,
  ) => constructed = "registerOutputs"
  @send
  external setOutputs: (
    ReventlessSpec.Component.t<t, ReventlessSpec.CommandTopic.outputs>,
    ReventlessSpec.CommandTopic.outputs,
  ) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  @set
  external setPublish: (
    ReventlessSpec.Component.t<t, ReventlessSpec.CommandTopic.outputs>,
    publish,
  ) => unit = "publish"
  @get
  external publish: ReventlessSpec.Component.t<t, ReventlessSpec.CommandTopic.outputs> => publish =
    "publish"
  @set
  external setPublishJsons: (
    ReventlessSpec.Component.t<t, ReventlessSpec.CommandTopic.outputs>,
    ReventlessSpec.CommandTopic.publishJsons,
  ) => unit = "publishJsons"
  @get
  external publishJsons: ReventlessSpec.Component.t<
    t,
    ReventlessSpec.CommandTopic.outputs,
  > => ReventlessSpec.CommandTopic.publishJsons = "publishJsons"

  let publishJsonsFn = connector => (. jsons) =>
    connector.Adapter.publish(. jsons)
    ->Js.Promise2.catch(e => {
      Js.log2(
        "CommandTopic: Couldn't publish commands:",
        jsons->Belt.Array.map(commandJson =>
          commandJson->Message.commandJson_encode->Js.Json.stringify
        ),
      )
      NotPublishedToConnector(e)->Js.Promise.reject
    })
    ->Js.Promise2.then(_ =>
      Js.log2(
        "CommandTopic: Published commands:",
        jsons->Belt.Array.map(commandJson =>
          commandJson->Message.commandJson_encode->Js.Json.stringify
        ),
      )->Js.Promise.resolve
    )

  let publishFn: Adapter.connector => (
    . Message.command'<Spec.Id.t, Spec.command>,
  ) => Js.Promise.t<unit> = connector => {
    (. command') => {
      let commandJson = {
        Message.id: command'.id->Spec.Id.toString,
        meta: command'.meta,
        commandJson: command'.command->Spec.command_encode,
        delay: None,
      }
      publishJsonsFn(connector)(. [commandJson])
    }
  }

  let handleCommands = commandsHandler => (. jsonItems) => {
    Js.log2("starting CommandTopic.handleCommands. Command count:", jsonItems->Belt.Array.size)
    let topicItems = jsonItems->Belt.Array.keepMap(({reference, command: json}) =>
      switch json->Message.command'_decode(Spec.Id.t_decode, Spec.command_decode, _) {
      | Belt_Result.Ok(command') => Some({reference, command: command'})
      | Belt_Result.Error(err) =>
        let commandStr = json->Js.Json.stringify
        let message = err.message
        Js.log(`CommandTopic: Error: Couldn't decode command ${commandStr}: ${message}`)
        None
      }
    )
    commandsHandler(. topicItems)
    ->Js.Promise2.then(res => {
      Js.log("finished CommandTopic.handleCommands")
      res->Js.Promise.resolve
    })
    ->Js.Promise2.catch(err => {
      let error = (err->Util.Error.ofPromise).message
      Js.Exn.raiseError(`CommandTopic.handleCommand: Error: Couldn't handle commands: ${error}`)
    })
  }

  let construct = (~memorySize, ~timeout, self, name, commandsHandler) => {
    let opts = Pulumi.CustomResourceOptions.make(~parent=self->Component.toPulumiResource, ())

    let connector = Connector.make(
      ~name=name->ComponentType.name(componentType),
      ~handleCommands=commandsHandler->handleCommands,
      ~memorySize,
      ~timeout,
      ~opts,
    )

    self->setPublish(connector->publishFn)
    self->setPublishJsons(connector->publishJsonsFn)

    self->setOutputs(makeOutputs(~resources=connector.resources))
  }

  let make = (~name, ~commandsHandler, ~memorySize=1024, ~timeout=30, ~opts=?, _) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~memorySize, ~timeout),
      ~opts,
      ~commandsHandler,
    )
}
