let componentType = ComponentType.CommandGenerator

type arguments = {id: string}
type meta = {ip: array<string>, user: string, info: string}
type payload = {
  command: string,
  arguments: arguments,
  meta: meta,
}
external asPayload: 'a => payload = "%identity"
type event = {meta?: meta}
external asEvent: 'a => event = "%identity"

let metaInfo = event => (event->asEvent).meta->Option.map(({info}) => info)

type commandGenerator = payload => Js.Promise.t<string>
type eventHandler<'context> = Runtime.eventHandler<payload, 'context, string>

type publishJsons = CommandTopic.publishJsons

type t
type outputs = {resources: array<ReventlessSpec.Adapter.resource>}
type component = Component.t<t, outputs, unit>

module type T = {
  type runtimeParts
  let connect: (
    ~name: string,
    ~commandGenerator: component,
    ~runtime: Runtime.environment<runtimeParts>,
    ~resources: array<ReventlessSpec.Adapter.resource>,
    ~opts: Pulumi.ComponentResource.options,
  ) => unit

  let makeHandler: (~publishJsons: publishJsons) => Pulumi.Output.t<eventHandler<'context>>

  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}
