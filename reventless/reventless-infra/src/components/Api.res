/** Type alias for schema fragments (re-exports Plugin.apiSchemaFragment). */
type schemaFragment = Reventless.Plugin.apiSchemaFragment

/**
Schema entry for a mutation field, derived from an aggregate command schema
or a DCB StateChangeSlice command schema. Consumed by GraphQL, MCP, and (future) OpenAPI generators.
`S.t<unknown>` is used for type-erasure — build entries with `Obj.magic`.
*/
type mutationSchemaEntry = {
  fieldNames: array<string>,
  commandSchema: S.t<unknown>,
  authorization?: Reventless.ReadModel.authorization,
  description?: string,
}

/**
Schema entry for a query field, derived from a ReadModel or StateViewSlice state schema.
Consumed by GraphQL, MCP, and (future) OpenAPI generators.
`S.t<unknown>` is used for type-erasure — build entries with `Obj.magic`.
*/
type querySchemaEntry = {
  singleFieldName: string,
  listFieldName: string,
  returnTypeName: string,
  stateSchema: S.t<unknown>,
  authorization: option<Reventless.ReadModel.authorization>,
  excludeFields?: array<string>,
  description?: string,
  includeIdParam?: bool,
  connectionSpec?: bool,
}

/**
Schema entry for an event log, derived from an aggregate EventLog or DCB EventLog.
Consumed by MCP (event history resources), GraphQL (future subscriptions),
and (future) OpenAPI/REST event endpoints.
*/
type eventLogSchemaEntry = {
  busKey: string,
  displayName: string,
  eventSchema: S.t<unknown>,
}

/**
Deploy-time outputs produced when an `Api` component is provisioned.
- `apiId` — the cloud API resource identifier (e.g. AppSync API ID)
*/
type outputs = {
  apiId: Pulumi.Output.t<string>,
}

/**
Runtime operations for the `Api` component.
- `updateSchema` — rebuild the stitched schema from the current plugin fragments
*/
type operations = {
  updateSchema: array<Reventless.Plugin.apiSchemaFragment> => promise<unit>,
}

type t
type component = Component.t<t, outputs, operations>

/**
Module type produced by `Platform.Api.Make(Config)`.
*/
module type T = {
  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}
