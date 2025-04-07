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
  type context
  type parts
  let make: environmentMaker<'event, context, 'result, parts>
}

type forComponent<'handler, 'parts, 'component> = (
  ~handler: Pulumi.Output.t<'handler>,
  ~memorySize: int=?,
  ~timeout: int=?,
  'component,
) => environment<'parts>
