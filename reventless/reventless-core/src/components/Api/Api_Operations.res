// Api_Operations — thin runtime wrapper for Api component operations.

/**
Trigger a schema rebuild on the given Api component with the supplied plugin fragments.
Returns a promise that resolves once the provider has published the new schema.
*/
let updateSchema = (
  api: ReventlessInfra.Api.component,
  fragments: array<Reventless.Plugin.apiSchemaFragment>,
): Pulumi.Output.t<promise<unit>> =>
  api
  ->Component.operations
  ->Pulumi.Output.apply(ops => ops.updateSchema(fragments))
