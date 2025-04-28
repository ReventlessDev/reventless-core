type eventHandler<'event, 'context, 'result> = ('event, 'context) => promise<'result>

type environment<'parts> = {
  parts: 'parts,
  resources: array<ReventlessSpec.Adapter.resource>,
}

type environmentMaker<'event, 'context, 'result, 'parts> = (
  ~name: string,
  ~handler: Pulumi.Output.t<eventHandler<'event, 'context, 'result>>,
  ~memorySize: int=?,
  ~timeout: int=?,
  ~opts: Pulumi.ComponentResource.options=?,
) => environment<'parts>

module type Environment = {
  type event
  type context
  type parts
  let make: environmentMaker<event, context, 'result, parts>
  let groupBySource: event => dict<event>
  let asEventHandler: 'a => eventHandler<event, context, 'result>
}

type connect<'parts> = (~runtime: environment<'parts>) => unit

type forComponent<'handler, 'parts, 'component> = (
  ~handler: Pulumi.Output.t<'handler>,
  ~connect: connect<'parts>,
  ~memorySize: int=?,
  ~timeout: int=?,
  'component,
) => unit

type forComponentNamed<'handler, 'parts, 'component> = (
  ~handler: Pulumi.Output.t<'handler>,
  ~connect: connect<'parts>,
  ~memorySize: int=?,
  ~timeout: int=?,
  ~name: string,
  'component,
) => unit

type forEventCollector<'handler, 'component> = (
  ~handler: Pulumi.Output.t<'handler>,
  ~eventTopics: EventTopic.allOutputs,
  ~resources: array<ReventlessSpec.Adapter.resource>,
  ~memorySize: int=?,
  ~timeout: int=?,
  'component,
) => unit
