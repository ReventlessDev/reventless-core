let componentType = ComponentType.CommandTopic

type unwrappedOutputs = {resources: array<Adapter.unwrappedResource>}

exception NotPublishedToConnector(Js.Promise.error)

module type T = {
  module Spec: ReventlessSpec.CommandTopic.Spec

  type t

  type commandsHandler = ReventlessSpec.CommandTopic.commandsHandler<
    Message.command'<Spec.Id.t, Spec.command>,
  >

  let make: (
    ~name: string,
    ~commandsHandler: commandsHandler,
    ~memorySize: int=?,
    ~timeout: int=?,
    ~opts: Pulumi.ComponentResource.options=?,
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
    resources: array<ReventlessSpec.Adapter.resource>,
    publish: Pulumi.Output.t<ReventlessSpec.CommandTopic.publishJsons>,
  }
  type connectorMaker = (
    ~name: string,
    ~handleCommands: ReventlessSpec.CommandTopic.commandsHandler<Js.Json.t>,
    ~memorySize: int,
    ~timeout: int,
    ~opts: Pulumi.CustomResourceOptions.t,
  ) => connector

  module type Connector = {
    let make: connectorMaker
  }

  type remoteConnector = {remotePublish: ReventlessSpec.CommandTopic.publishJsons}
  type remoteConnectorMaker = array<ReventlessSpec.Adapter.resource> => remoteConnector

  module type RemoteConnector = {
    let make: remoteConnectorMaker
  }
}

module Make = (Spec: ReventlessSpec.CommandTopic.Spec, Connector: Adapter.Connector): (
  T with module Spec = Spec
) => {
  module Spec = Spec

  type t

  type commandsHandler = ReventlessSpec.CommandTopic.commandsHandler<
    Message.command'<Spec.Id.t, Spec.command>,
  >

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
    ~opts: option<Pulumi.ComponentResource.options>,
    ~commandsHandler: commandsHandler,
  ) => ReventlessSpec.Component.t<t, ReventlessSpec.CommandTopic.outputs> = "default"

  @obj
  external makeOutputs: (
    ~resources: array<ReventlessSpec.Adapter.resource>,
  ) => ReventlessSpec.CommandTopic.outputs = ""

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

  let publishJsonsFn = publish =>
    async cmdJsons =>
      switch await publish(cmdJsons) {
      | exception e =>
        cmdJsons->Logger.logCmdJsons(
          ~level=Logger.Level.Error,
          ~loc=__LOC__,
          "Couldn't publish commands",
        )
        raise(e)
      | _ => cmdJsons->Logger.logCmdJsons(~loc=__LOC__, "Published commands")
      }

  let publishFn = (publish, command': Message.command'<Spec.Id.t, Spec.command>) => {
    let commandJson = {
      Message.id: command'.id->Spec.Id.toString,
      meta: command'.meta,
      commandJson: command'.command->Spec.command_encode,
      delay: None,
    }
    publishJsonsFn(publish)([commandJson])
  }

  let construct = (~memorySize, ~timeout, self, name, commandsHandler) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    module Runtime = CommandTopic_Runtime.Make(Spec)

    let connector = Connector.make(
      ~name=name->ComponentType.name(componentType),
      ~handleCommands=commandsHandler->Runtime.handleCommands,
      ~memorySize,
      ~timeout,
      ~opts,
    )

    let _ = connector.publish->Pulumi.Output.apply(publish => {
      self->setPublish(publishFn(publish, ...))
      self->setPublishJsons(publishJsonsFn(publish, ...))
    })

    self->setOutputs(makeOutputs(~resources=connector.resources))
  }

  let make = (~name, ~commandsHandler, ~memorySize=1024, ~timeout=30, ~opts=?) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~memorySize, ~timeout, ...),
      ~opts,
      ~commandsHandler,
    )
}
