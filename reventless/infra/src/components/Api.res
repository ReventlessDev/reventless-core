// --- Sury metadata IDs for API exposure control ---

/** Internal sury metadata ID used to mark a schema as excluded from API exposure. */
let noApiId: S.Metadata.Id.t<bool> = S.Metadata.Id.make(~namespace="api", ~name="noApi")

/** Internal sury metadata ID used to mark specific variant names excluded from API exposure. */
let noApiVariantsId: S.Metadata.Id.t<Set.t<string>> =
  S.Metadata.Id.make(~namespace="api", ~name="noApiVariants")

/** Internal sury metadata ID storing per-variant allowed-state lists for AutoUI command filtering.
    Maps variant name → set of status values under which the command is meaningful. */
let allowedStatesId: S.Metadata.Id.t<dict<array<string>>> =
  S.Metadata.Id.make(~namespace="api", ~name="allowedStates")

/** Internal sury metadata ID storing per-variant target-state values for AutoUI board
    transitions. Maps variant name → the single status the command's handler writes. */
let targetStateId: S.Metadata.Id.t<dict<string>> =
  S.Metadata.Id.make(~namespace="api", ~name="targetState")

/** PPX helper: attaches the noApi flag to a command schema. Called by generated code. */
let markNoApi = (schema: S.t<'a>): S.t<'a> =>
  schema->S.Metadata.set(~id=noApiId, true)

/** PPX helper: attaches variant-level exclusions to a command schema. Called by generated code. */
let markNoApiVariants = (schema: S.t<'a>, variants: array<string>): S.t<'a> =>
  schema->S.Metadata.set(~id=noApiVariantsId, Set.fromArray(variants))

/** PPX helper: attaches per-variant allowedStates to a command schema. Called by generated code
    emitted from the @allowedStates([…]) attribute. Each entry is (variantName, allowedStateNames). */
let markAllowedStates = (
  schema: S.t<'a>,
  entries: array<(string, array<string>)>,
): S.t<'a> => schema->S.Metadata.set(~id=allowedStatesId, Dict.fromArray(entries))

/** PPX helper: attaches per-variant targetState to a command schema. Called by generated code
    emitted from the @targetState("…") attribute. Each entry is (variantName, targetStateName). */
let markTargetState = (
  schema: S.t<'a>,
  entries: array<(string, string)>,
): S.t<'a> => schema->S.Metadata.set(~id=targetStateId, Dict.fromArray(entries))

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
  /** Opt a mutation field into deploy-time IAM (SigV4) invocation in addition to
      its Cognito authorization. When `true`, the AWS provider emits the
      multi-auth directive form `@aws_cognito_user_pools(cognito_groups: [...])
      @aws_iam` on the field instead of the single-mode `@aws_auth(...)`, so a
      deploy-time system caller signing with ambient AWS credentials
      (`Util_AppSync_Caller`) is authorized alongside the console UI. Opt-in per
      field — only fields a system caller actually invokes should set this, and
      the IAM principal must be scoped by the API resource policy / deploy-role
      policy (see `docs/guides/appsync-iam-system-caller.md`). Default `false`. */
  systemCallable?: bool,
  /** Whether the generated mutation field carries a separate `id: ID!` argument
      naming the target entity, injected ahead of the command payload args.
      `true` for aggregate mutations — the aggregate instance id is a real
      argument distinct from the command payload (e.g.
      `Ordering_Customer_Register(id: ID!, email: String!, ...)`), and callers
      send it as `id`. `false` for DCB slice / inbound-translation mutations —
      the slice's own key field (e.g. `orderId`) is part of the payload and no
      separate `id` argument exists. Defaults to `true` so aggregate entries
      (including the admin Plugin fragment) keep the injection without opting in.
      A multi-variant slice command schema is a sury `Union`, so without this
      flag it would wrongly inherit the aggregate-style `id: ID!` injection. */
  injectIdArg?: bool,
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
  /** Read-model `Spec.name`. Used as the key for
      `Plugin_Helpers.queryFieldNamesRegistry` / `stateSchemaRegistry`, which
      `QueryDbResolvers_{AppSync,GraphQL}.make` looks up by the same key
      (`Spec.name`). When unset, the admin populator falls back to the
      singular form derived from `returnTypeName` — kept for backward compat
      with read-model specs whose `Spec.name` matches the entity type name.
      Must be set when the read model uses a
      plural `Spec.name` (e.g. `Plugins`) so the registry key still matches. */
  specName?: string,
  authorization: option<Reventless.ReadModel.authorization>,
  /** Spec-level read-model authorization derived from `Spec.authorization`.
      Applies to both the single-id and list query fields. Used by AWS to
      inject `@aws_auth(cognito_groups: ...)` (Stage E2 in
      `docs/plans/host-ui-login-core.md`). In-memory enforcement happens at
      the QueryDb resolver via the same field. */
  permission?: Reventless.Authorization.permission,
  /** Opt the single-id and list query fields into deploy-time IAM (SigV4)
      invocation in addition to their Cognito authorization. See
      `mutationSchemaEntry.systemCallable` for the emitted directive form and
      scoping requirements. Default `false`. */
  systemCallable?: bool,
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

// (The Api component contract — outputs/operations/`module type T` and the
// whole `updateSchema` push chain — was retired with the merged-API cutover:
// AWS composes source APIs via SourceApiAssociation and the local platform
// composes in-process; nothing rebuilds a stitched schema at runtime. The
// schema-entry types above remain the live surface, consumed by
// `Api_Adapter.Provider.generateFragment` and the MCP/AutoUI generators.)
