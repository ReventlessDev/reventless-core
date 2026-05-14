// --- Sury metadata IDs for API exposure control ---

/** Internal sury metadata ID used to mark a schema as excluded from API exposure. */
let noApiId: S.Metadata.Id.t<bool> = S.Metadata.Id.make(~namespace="api", ~name="noApi")

/** Internal sury metadata ID used to mark specific variant names excluded from API exposure. */
let noApiVariantsId: S.Metadata.Id.t<Set.t<string>> =
  S.Metadata.Id.make(~namespace="api", ~name="noApiVariants")

/** PPX helper: attaches the noApi flag to a command schema. Called by generated code. */
let markNoApi = (schema: S.t<'a>): S.t<'a> =>
  schema->S.Metadata.set(~id=noApiId, true)

/** PPX helper: attaches variant-level exclusions to a command schema. Called by generated code. */
let markNoApiVariants = (schema: S.t<'a>, variants: array<string>): S.t<'a> =>
  schema->S.Metadata.set(~id=noApiVariantsId, Set.fromArray(variants))

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
  /** Spec-level per-field authorization derived from `Spec.commandAuthorization`,
      keyed by mutation field name. Used by AWS to inject
      `@aws_auth(cognito_groups: ...)` per field (Stage E2 in
      `docs/plans/host-ui-login-core.md`). In-memory enforcement still happens
      at the resolver layer via the same `commandAuthorization` function. */
  fieldPermissions?: dict<Reventless.Authorization.permission>,
  description?: string,
  linkedViews?: array<string>,
  consistencyRead?: string,
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
  /** Spec-level read-model authorization derived from `Spec.authorization`.
      Applies to both the single-id and list query fields. Used by AWS to
      inject `@aws_auth(cognito_groups: ...)` (Stage E2 in
      `docs/plans/host-ui-login-core.md`). In-memory enforcement happens at
      the QueryDb resolver via the same field. */
  permission?: Reventless.Authorization.permission,
  excludeFields?: array<string>,
  description?: string,
  includeIdParam?: bool,
  connectionSpec?: bool,
  /** When set, generates a `{singleFieldName}ById` sort-key query with sort condition args. */
  subIdField?: string,
  /** When set, generates `{singleFieldName}By{Index}` connection query fields for each GSI. */
  indexQueries?: array<Reventless.ReadModel.indexConfig>,
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
