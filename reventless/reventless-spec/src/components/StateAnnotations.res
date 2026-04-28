/**
Spec describing the structural annotations declared on the fields of an
`@schema type state` record. The ppx attaches one of these to the generated
`stateSchema` whenever a field carries a structural annotation (`@id`,
`@compositeId`, `@subId`, `@compositeSubId`, `@index`), a visibility
annotation (`@hidden`, `@summary`), a hierarchical-rendering annotation
(`@drillTarget`, `@collapsed`), or a server-query opt-in annotation
(`@scan`, `@scanSort`). Downstream consumers (UI, MCP, codegen) read the
spec to surface field roles in JSON Schema as `x-reventless-*` extension
properties.

Each list contains the source field names; `indexes` carries `(fieldName,
indexName)` pairs where `indexName` is `""` for unnamed `@index` annotations.
`hidden` lists fields the UI should suppress from summary/list views;
`summary` lists fields the UI should always include in summary/list views.
`drillTargets` carries `(fieldName, sliceName)` pairs naming the slice/view
the UI should navigate to instead of expanding the field inline;
`drillTargetKeys` carries `(fieldName, keyPath)` pairs for fields whose
drill-down target is keyed by a sub-path within the array element;
`collapsed` lists object-typed fields the UI should render as an inline
summary rather than expanding. `scan` lists fields the type author opted
into server-side equality filtering on (without a backing index); `scanSort`
lists fields the type author opted into server-side sorting on. The cost is
free on the in-memory adapter but is `O(n)` Scan + FilterExpression on
DynamoDB-backed adapters — the annotation is the explicit signal that the
read model is small enough or the cost is acceptable.
*/
type stateAnnotationSpec = {
  ids: array<string>,
  compositeIds: array<string>,
  subIds: array<string>,
  compositeSubIds: array<string>,
  indexes: array<(string, string)>,
  hidden: array<string>,
  summary: array<string>,
  drillTargets: array<(string, string)>,
  drillTargetKeys: array<(string, string)>,
  collapsed: array<string>,
  scan: array<string>,
  scanSort: array<string>,
}

/** Sury metadata ID used to attach a `stateAnnotationSpec` to a state schema. */
let stateAnnotationsId: S.Metadata.Id.t<stateAnnotationSpec> =
  S.Metadata.Id.make(~namespace="reventless", ~name="stateAnnotations")

/** Returns the spec attached to a state schema, if any. */
let getSpec = (schema: S.t<unknown>): option<stateAnnotationSpec> =>
  S.Metadata.get(schema, ~id=stateAnnotationsId)
