let componentType = ComponentType.CommandGenerator

type arguments = {id: string}
type meta = {ip: array<string>, user: string, info: string}
type payload = {
  command: string,
  arguments: arguments,
  meta: meta,
  identity: Reventless.Identity.t,
}
external asPayload: 'a => payload = "%identity"
type event = {meta?: meta}
external asEvent: 'a => event = "%identity"

let metaInfo = event => (event->asEvent).meta->Option.map(({info}) => info)

type commandGenerator = payload => Effect.t<CommandTopic.commandOutcome, unit, unit>
type effectEventHandler<'context> = Runtime.effectHandler<payload, 'context, CommandTopic.commandOutcome, unit>

type publishJsons = CommandTopic.publishJsons

type t
type outputs = ReventlessInfra.CommandGenerator.outputs
type component = Component.t<t, outputs, unit>

module type T = {
  type api
  type runtimeParts
  let connect: (
    ~api: api,
    ~resources: array<ReventlessInfra.Adapter.resource>,
    ~runtime: Runtime.environment<runtimeParts>,
    component,
  ) => unit

  let makeHandler: (
    ~publishJsons: publishJsons,
    ~publishJsonsAndWait: option<CommandTopic.publishJsonsAndWait>,
  ) => Pulumi.Output.t<effectEventHandler<'context>>

  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}
