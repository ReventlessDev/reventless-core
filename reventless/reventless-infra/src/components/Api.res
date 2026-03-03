/** Type alias for schema fragments (re-exports Plugin.apiSchemaFragment). */
type schemaFragment = Reventless.Plugin.apiSchemaFragment

/**
Schema entry for a GraphQL mutation field, derived from an aggregate command schema
or a DCB StateChangeSlice command schema.
`S.t<unknown>` is used for type-erasure — build entries with `Obj.magic`.
*/
type mutationSchemaEntry = {
  fieldNames: array<string>,
  commandSchema: S.t<unknown>,
  description?: string,
}

/**
Schema entry for a GraphQL query field, derived from a ReadModel or StateViewSlice state schema.
`S.t<unknown>` is used for type-erasure — build entries with `Obj.magic`.
*/
type querySchemaEntry = {
  singleFieldName: string,
  listFieldName: option<string>,
  returnTypeName: string,
  stateSchema: S.t<unknown>,
  authorization: option<Reventless.ReadModel.authorization>,
  description?: string,
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
