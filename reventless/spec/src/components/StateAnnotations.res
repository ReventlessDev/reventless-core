/**
Spec describing the structural annotations declared on the fields of an
`@schema type state` record. The ppx attaches one of these to the generated
`stateSchema` whenever a field carries a structural annotation (`@id`,
`@compositeId`, `@subId`, `@compositeSubId`, `@index`), a visibility
annotation (`@hidden`, `@summary`), a hierarchical-rendering annotation
(`@drillTarget`, `@collapsed`), a server-query opt-in annotation
(`@scan`, `@scanSort`), a UI-list annotation (`@status`, `@groupBy`), or a
type-level live-updates annotation (`@live` on the `state` declaration).
Downstream consumers (UI, MCP, codegen) read the
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
/**
Declared aggregation for a `@metric`-annotated numeric field. `aggregate` is one
of `"count"`, `"sum"`, `"avg"` (the UI's dashboard vocabulary); `label` is the
KPI label, or `""` to let the UI derive one from the field name.
*/
type metricSpec = {aggregate: string, label: string}

/**
The boolean field declared `@retired`, and how a consumer should title it.

`field` names the boolean whose truth withdraws the row from ordinary use — a
deactivated customer, an archived category. `label` is what that state is called
("Archived"), or `""` to let a consumer derive one from the field name.
`showWhenFalse` asks a consumer to surface the flag in its negative state too;
the default is false, because a caller who is not exempt from the narrowing never
receives a retired row and would otherwise see the same negative marker on every
record they can read.

The narrowing itself is not described here. This spec carries what the field
*means*; who still sees a retired row is one deployment-wide rule
(`OwnerScope.elevatedGroups`), resolved where the query is answered.
*/
type retiredSpec = {field: string, label: string, showWhenFalse: bool}

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
  /**
  Fields annotated `@semantic("<id>")` — `(fieldName, semanticId)` pairs. The
  semantic id is the UI's `AutoSemantics` vocabulary (e.g. `"currency"`,
  `"geo-lat"`); the PPX can't validate it (the UI owns that vocabulary).
  `SuryToJsonSchema` emits `x-reventless-semantic` on the named field, which
  AutoUI reads at `#Annotation` provenance — above its heuristic, below a
  `ui-hints.json` `fields:` override.
  */
  semantic: array<(string, string)>,
  /**
  Fields annotated `@metric(...)` — `(fieldName, metricSpec)` pairs.
  `SuryToJsonSchema` emits `x-reventless-metric: {aggregate, label}` on the named
  field, which AutoUI folds into the dashboard metric list it already builds from
  hints — so a plugin gets a Dashboard page from its schema alone.
  */
  metric: array<(string, metricSpec)>,
  /**
  Field annotated `@status` on the state record (PPX-emitted). `Some(name)`
  when one such annotation exists; the PPX errors on duplicate `@status`
  annotations within the same record. Codegen consumes this to populate
  `queryableDef.statusField` (with a fallback to a field literally named
  `"status"` when this annotation is absent).
  */
  status: option<string>,
  /**
  Field annotated `@groupBy` on the state record (PPX-emitted). `Some(name)`
  when one such annotation exists; the PPX errors on duplicate `@groupBy`
  annotations within the same record. `SuryToJsonSchema.deriveObjectSchema`
  emits `x-reventless-group-by: true` on the named field, which the UI's
  list view reads to render rows in sections keyed on that field.
  */
  groupBy: option<string>,
  /**
  Component-level visibility hint from `@@reventless.visibility(...)`.
  `Some("Internal")` when the file-level attribute is `Internal`; `None`
  (omitted) for the default `Public`. `SuryToJsonSchema.deriveObjectSchema`
  emits `x-reventless-visibility: "Internal"` on the schema when present —
  the default case is omitted to keep schemas compact.
  */
  visibility: option<string>,
  /**
  Component-level live-updates hint from `@live(true | false)` on the
  `@schema type state` declaration (PPX-emitted). `SuryToJsonSchema.deriveObjectSchema`
  emits top-level `x-reventless-live: bool` when present; absent annotation ⇒
  key absent ⇒ the consumer's own default applies. The framework only
  transports the declaration — UI consumers decide whether a live-updates
  control is offered (`true`) or hidden (`false`) for the view.
  */
  live: option<bool>,
  /**
  Field annotated `@retired` on the state record (PPX-emitted). `Some(spec)` when
  one such annotation exists; the PPX errors on duplicates and on a non-boolean
  field. `SuryToJsonSchema.deriveObjectSchema` emits `x-reventless-retired:
  {label?, showWhenFalse}` on the named field.

  `option<retiredSpec>` rather than an array: at most one per record. Two
  retirement flags are not a stricter rule but an unanswered one — the read
  predicate would have to guess whether they conjoin or disjoin, and the query
  layer narrows on a single field.
  */
  retired: option<retiredSpec>,
}

/** Sury metadata ID used to attach a `stateAnnotationSpec` to a state schema. */
let stateAnnotationsId: S.Metadata.Id.t<stateAnnotationSpec> =
  S.Metadata.Id.make(~namespace="reventless", ~name="stateAnnotations")

/** Returns the spec attached to a state schema, if any. */
let getSpec = (schema: S.t<unknown>): option<stateAnnotationSpec> =>
  S.Metadata.get(schema, ~id=stateAnnotationsId)
