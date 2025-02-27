let componentType = ComponentType.CommandGenerator

type arguments = {id: string}
type meta = {ip: array<string>, user: string}
type payload = {
  command: string,
  arguments: arguments,
  meta: meta,
}
type commandGenerator = payload => Js.Promise.t<string>
type publishJsons = CommandTopic.publishJsons

type t
type outputs = {resources: array<ReventlessSpec.Adapter.resource>}
type component = Component.t<t, outputs, unit>

module type T = {
  let makeHandler: (
    ~publishJsons: publishJsons,
  ) => Pulumi.Output.t<Runtime.eventHandler<payload, 'context, string>>

  let make: (
    ~name: string,
    ~runtime: Runtime.environment,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
