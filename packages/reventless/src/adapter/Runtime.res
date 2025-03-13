type eventHandler<'event, 'context, 'result> = ('event, 'context) => promise<'result>

type environment = {resources: array<ReventlessSpec.Adapter.resource>}

type environmentMaker<'event, 'context, 'result> = (
  ~name: string,
  ~handler: Pulumi.Output.t<eventHandler<'event, 'context, 'result>>,
  ~memorySize: int=?,
  ~timeout: int=?,
  ~opts: Pulumi.ComponentResource.options=?,
) => environment

module type Environment = {
  type context
  let make: environmentMaker<'event, context, 'result>
}
