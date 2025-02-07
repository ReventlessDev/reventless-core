let componentType = ComponentType.CommandTopic

type outputs = {resources: array<ReventlessSpec.Adapter.resource>}

type unwrappedOutputs = {resources: array<Adapter.unwrappedResource>}

type t
type component = Component.t<t, outputs>

exception NotPublishedToConnector(Js.Promise.error)

module type T = {
  module Spec: ReventlessSpec.CommandTopic.Spec

  type commandsHandler = ReventlessSpec.CommandTopic.commandsHandler<
    Message.command'<Spec.Id.t, Spec.command>,
  >

  let make: (
    ~name: string,
    ~commandsHandler: commandsHandler,
    ~memorySize: int=?,
    ~timeout: int=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component

  let publish: component => Pulumi.Output.t<
    ReventlessSpec.CommandTopic.publish<Spec.Id.t, Spec.command>,
  >
  let publishJsons: component => Pulumi.Output.t<ReventlessSpec.CommandTopic.publishJsons>
}

module Adapter = {
  type connector = {
    resources: array<ReventlessSpec.Adapter.resource>,
    publishJsons: Pulumi.Output.t<ReventlessSpec.CommandTopic.publishJsons>,
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

  type remoteConnector = {remotePublish: Pulumi.Output.t<ReventlessSpec.CommandTopic.publishJsons>}
  type remoteConnectorMaker = Pulumi.Output.t<
    array<Reventless.Adapter.unwrappedResource>,
  > => remoteConnector

  module type RemoteConnector = {
    let make: remoteConnectorMaker
  }
}

module Make = (Spec: ReventlessSpec.CommandTopic.Spec, Connector: Adapter.Connector): (
  T with module Spec = Spec
) => {
  module Spec = Spec

  type commandsHandler = ReventlessSpec.CommandTopic.commandsHandler<
    Message.command'<Spec.Id.t, Spec.command>,
  >

  type constructed
  type construct = (component, string, commandsHandler) => constructed

  type publish = ReventlessSpec.CommandTopic.publish<Spec.Id.t, Spec.command>

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
    ~commandsHandler: commandsHandler,
  ) => component = "default"

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send
  external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  @set
  external setPublish: (component, Pulumi.Output.t<publish>) => unit = "publish"
  @get
  external publish: component => Pulumi.Output.t<publish> = "publish"
  @set
  external setPublishJsons: (
    component,
    Pulumi.Output.t<ReventlessSpec.CommandTopic.publishJsons>,
  ) => unit = "publishJsons"
  @get
  external publishJsons: component => Pulumi.Output.t<ReventlessSpec.CommandTopic.publishJsons> =
    "publishJsons"

  let publishJsonsFn = publishJsons =>
    async cmdJsons =>
      switch await publishJsons(cmdJsons) {
      | exception e =>
        cmdJsons->Logger.logCmdJsons(
          ~level=Logger.Level.Error,
          ~loc=__LOC__,
          "Couldn't publish commands",
        )
        raise(e)
      | _ => cmdJsons->Logger.logCmdJsons(~loc=__LOC__, "Published commands")
      }

  let publishFn = (publishJsons, command': Message.command'<Spec.Id.t, Spec.command>) => {
    let commandJson = {
      Message.id: command'.id->Spec.Id.toString,
      meta: command'.meta,
      commandJson: command'.command->Spec.command_encode,
      delay: None,
    }
    publishJsonsFn(publishJsons)([commandJson])
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

    self->setPublish(
      connector.publishJsons->Pulumi.Output.apply(publishJsons => publishFn(publishJsons, ...)),
    )
    self->setPublishJsons(
      connector.publishJsons->Pulumi.Output.apply(publishJsons =>
        publishJsonsFn(publishJsons, ...)
      ),
    )

    self->setOutputs({resources: connector.resources})
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
