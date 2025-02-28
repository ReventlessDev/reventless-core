let componentType = ComponentType.Heartbeat

type outputs = {name: string, resources: array<ReventlessSpec.Adapter.resource>}

type t
type component = Component.t<t, outputs, unit>

module type T = {
  let makeHandler: (
    ~id: string,
    ~timeout: int=?,
    ~publishToCorePluginExtensionPoint: CommandTopic.publishJsons,
  ) => Pulumi.Output.t<Runtime.eventHandler<unit, 'context, unit>>

  let make: (~name: string, ~timeout: int) => component
}
