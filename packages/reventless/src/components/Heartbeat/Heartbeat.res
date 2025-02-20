let componentType = ComponentType.Heartbeat

type outputs = {name: string, resources: array<ReventlessSpec.Adapter.resource>}

type t
type component = Component.t<t, outputs, unit>

module type T = {
  let make: (
    ~id: string,
    ~name: string,
    ~timeout: int,
    ~publishToCorePluginExtensionPoint: CommandTopic.publishJsons,
  ) => component
}
