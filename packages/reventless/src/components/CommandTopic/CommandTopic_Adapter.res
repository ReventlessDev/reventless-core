type connector = {
  resources: array<ReventlessSpec.Adapter.resource>,
  publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
}
type connectorMaker = (
  ~name: string,
  ~handleCommands: CommandTopic.commandsHandler<Js.Json.t>,
  ~memorySize: int,
  ~timeout: int,
  ~opts: Pulumi.CustomResourceOptions.t,
) => connector

module type Connector = {
  let make: connectorMaker
}

type remoteConnector = {remotePublish: Pulumi.Output.t<CommandTopic.publishJsons>}
type remoteConnectorMaker = Pulumi.Output.t<
  array<Reventless.Adapter.unwrappedResource>,
> => remoteConnector

module type RemoteConnector = {
  let make: remoteConnectorMaker
}
