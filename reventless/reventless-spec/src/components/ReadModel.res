/**
Specifies how the sub-ID of a projected state row is supplied at query time.

- `Field(name)` — the sub-ID comes from a field in the query response
- `Argument(name)` — the sub-ID is passed as a GraphQL resolver argument
- `NoSubId` — the read model has no sub-ID dimension
*/
type subId =
  | Field(string)
  | Argument(string)
  | NoSubId

/**
Whether the GraphQL resolver field resolves to a single value or to a list.

- `Single(fieldName)` — returns one item by ID
- `Multi(fieldName)` — returns an array of items
*/
type resolvedField =
  | Single(string)
  | Multi(string)

/** Source configuration for a single-ID GraphQL resolver. */
type idResolverSourceConfig = {
  idField: string,
  subId: subId,
  resolvedField: resolvedField,
}

/**
Specifies which DynamoDB table field serves as the primary key in the resolver target.

- `Index(indexName)` — resolve against an index using only the index ID
- `IndexWithId(indexName, idField)` — resolve against an index with an explicit ID field
- `Id` — resolve against the table's primary key
*/
type targetIdField =
  | Index(string)
  | IndexWithId(string, string)
  | Id

/** Target configuration for a single-ID GraphQL resolver. */
type idResolverTargetConfig = {
  pluginName?: string,
  tableName: string,
  idField: targetIdField,
  subIdField?: string,
}

type resolveConfig<'source, 'target> = {
  source: 'source,
  target: 'target,
}

/** Configuration for a GraphQL resolver that resolves a single ID field. */
type idResolverConfig = resolveConfig<idResolverSourceConfig, idResolverTargetConfig>

/** Source configuration for a multi-ID (array) GraphQL resolver. */
type idsResolverSourceConfig = {
  idsField: string,
  resolvedField: string,
}

/** Target configuration for a multi-ID (array) GraphQL resolver. */
type idsResolverTargetConfig = {
  pluginName?: string,
  tableName: string,
  subIdField?: string,
}

/** Configuration for a GraphQL resolver that resolves an array of ID fields. */
type idsResolverConfig = resolveConfig<idsResolverSourceConfig, idsResolverTargetConfig>

/** AppSync authorization rule associating a DynamoDB table with a Cognito group. */
type authorization = {
  tableName: string,
  group: string,
}

/** How much of a DynamoDB global secondary index is projected into the index. */
type projectionType = KEYS_ONLY | ALL | INCLUDE(array<string>)

/**
Configuration for a DynamoDB Global Secondary Index on a read model table.

- `index` — the index name
- `type_` — the DynamoDB attribute type of the index key (`"S"`, `"N"`, etc.)
- `idField` / `subIdField` — index key field overrides
- `projectionType` — which attributes are projected into the index
- `authorization` — optional AppSync authorization rule
*/
type indexConfig = {
  index: string,
  type_: string,
  idField?: string,
  subIdField?: string,
  projectionType: projectionType,
  authorization?: authorization,
}

/**
Composite-key configuration for a read model that has both a primary ID and a sub-ID.

- `subIdField` — the DynamoDB range-key attribute name
- `getSubId` — extracts the sub-ID string from a projected state value
*/
type subIdConfig<'state> = {
  subIdField: string,
  getSubId: 'state => string,
}

/**
Infrastructure configuration for a read model.

- `idResolvers` — GraphQL resolvers for single-ID lookups
- `idsResolvers` — GraphQL resolvers for multi-ID (array) lookups
- `indexes` — additional DynamoDB global secondary indexes

Use the `config` factory function to build this with defaults.
*/
type config = {
  idResolvers: array<idResolverConfig>,
  idsResolvers: array<idsResolverConfig>,
  indexes: array<indexConfig>,
}

/**
Builds a `ReadModel.config` with all optional fields defaulting to empty arrays.

@example
```rescript
// CategoriesReadModel.res
let config = ReadModel.config()
```
*/
let config = (~idResolvers=[], ~idsResolvers=[], ~indexes=[]) => {
  idResolvers,
  idsResolvers,
  indexes,
}

/**
Module type for a read model's identity and schema specification.

@example
```rescript
// CategoriesReadModel.res
module Id = Id.String
let name = "Categories"

@schema
type state = {categoryId: string, name: string, archived: bool}

let config = ReadModel.config()
let subIdConfig = None
```
*/
module type Spec = {
  module Id: Id.T

  /** Logical read model name, used as the DynamoDB table-name prefix. */
  let name: string

  /** The projected state type stored in the read model. Must carry `@schema`. */
  @schema
  type state

  /** Infrastructure configuration (indexes, resolvers). */
  let config: config

  /** Optional composite-key configuration. `None` for single-key tables. */
  let subIdConfig: option<subIdConfig<state>>
}

/**
Deploy-time outputs produced when a `ReadModel` is provisioned.

- `name` — the read model's logical name
- `queryDb` — the underlying query database outputs (DynamoDB table)
- `eventCollector` — the inbound event queue
- `sourceNames` — names of all aggregates whose events feed this read model
*/
type outputs = {
  name: string,
  queryDb: QueryDb.outputs,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
  sourceNames: array<string>,
}

/**
Runtime operations exposed by a `ReadModel` component.
Used by the aggregate runtime to push events into the read model's event queue.
*/
type operations = {enqueueEvent: EventCollector.enqueueEvent}

/**
Module type produced by `Platform.ReadModel.Make(Spec, Mappings)`.

@example
```rescript
// CatalogPlugin.res
module CategoryReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoryMappings)

let rm = CategoryReadModel.make(~api, ~apiRole, ~allEventTopics, ~opts=?)
```
*/
module type T = {
  module Spec: Spec
  type api
  type role
  type component
  let make: (
    ~api: api,
    ~apiRole: role,
    ~allEventTopics: EventTopic.allOutputs,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
  let outputs: component => outputs
  let operations: component => Pulumi.Output.t<operations>
  /** Signal that all sources have been registered; finalises the read model. */
  let finish: unit => unit
}
