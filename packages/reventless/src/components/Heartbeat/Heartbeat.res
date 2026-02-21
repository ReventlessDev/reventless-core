let componentType = ComponentType.Heartbeat

type outputs = ReventlessSpec.Heartbeat.outputs

type t
type component = Component.t<t, outputs, unit>

module type T = {
  type runtimeParts

  let connect: (
    ~runtime: Runtime.environment<runtimeParts>,
    ~remoteChannel: CommandTopic_Adapter.remoteChannel,
    ~timeout: int=?,
    component,
  ) => unit

  let makeHandler: (
    ~id: string,
    ~timeout: int=?,
    ~publishToCorePluginExtensionPoint: CommandTopic.publishJsons,
  ) => Pulumi.Output.t<Runtime.eventHandler<unit, 'context, unit>>

  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}
