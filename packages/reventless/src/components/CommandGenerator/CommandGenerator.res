let componentType = ComponentType.CommandGenerator

type outputs = {resources: array<ReventlessSpec.Adapter.resource>}

type t
type component = Component.t<t, outputs, unit>

module type T = {
  let make: (
    ~name: string,
    ~publishJsons: CommandTopic.publishJsons,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
