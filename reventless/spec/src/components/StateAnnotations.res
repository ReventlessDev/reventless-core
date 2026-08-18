/**
Spec describing the structural annotations declared on the fields of an
`@schema type state` record. The ppx attaches one of these to the generated
`stateSchema` whenever a field carries a structural annotation (`@id`,
`@compositeId`, `@subId`, `@compositeSubId`, `@index`), a visibility
annotation (`@hidden`, `@summary`), a hierarchical-rendering annotation
(`@drillTarget`, `@collapsed`), a server-query opt-in annotation
(`@scan`, `@scanSort`), a UI-list annotation (`@lifecycle`, `@groupBy`), or a
type-level live-updates annotation (`@live` on the `state` declaration).
Downstream consumers (UI, MCP, codegen) read the
spec to surface field roles in JSON Schema as `x-reventless-*` extension
properties.

Each list contains the source field names; `indexes` carries `(fieldName,
indexName)` pairs where `indexName` is `""` for unnamed `@index` annotations.
`hidden` lists fields the UI should suppress from summary/list views;
`summary` lists fields the UI should always include in summary/list views.
`internal` lists fields that are not on the GraphQL surface at all — see the
field's own note below; it is a different kind of claim from `hidden`.
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
The field declared `@retired`, and how a consumer should title it.

`field` names what withdraws the row from ordinary use — a deactivated customer,
an archived category. `label` is what that state is called ("Archived"), or `""`
to let a consumer derive one from the field name. `showWhenFalse` asks a consumer
to surface the flag in its negative state too; the default is false, because a
caller who is not exempt from the narrowing never receives a retired row and would
otherwise see the same negative marker on every record they can read.

`value` is what decides which of the two forms this is:

- `None` — the **boolean** form. The row is retired when the field is `true`. The
  right shape for a record whose retirement genuinely is a flag: a `Products` view
  with an `archived` boolean and no lifecycle should not have to invent a
  two-valued enum.
- `Some(v)` — the **state** form. The row is retired when the field equals `v`,
  and the field is the record's `@lifecycle` field. One field then carries the
  fact once instead of twice, and `@transition(([Deactivated]) => Active)` on the
  way-back command is enough to make a generated menu offer it there and nowhere
  else —
  because retirement is finally expressible in the vocabulary that stance is
  already written in.

The narrowing itself is not described here. This spec carries what the field
*means*; who still sees a retired row is one deployment-wide rule
(`OwnerScope.elevatedGroups`), resolved where the query is answered.
*/
type retiredSpec = {
  field: string,
  label: string,
  showWhenFalse: bool,
  /**
  The states that withdraw the row, or `None` for the boolean form.

  A **set**, because a lifecycle may end in more than one way — a product is
  withdrawn `Archived` or `Discontinued`, by different routes and with different
  ways back — and one field carries all of them. Retired iff the field's value is
  in the set; a single-element set is the ordinary case rather than a special one.

  The `option` is the **form discriminator** and is load-bearing. `None` is the
  boolean form, where the row is retired when the field is `true`. Flattened to a
  bare array, `[]` would mean both "boolean form" and "state form naming no
  states", and every consumer's boolean-form handling — the column suppression
  most visibly — would stop firing on a value that looks merely empty.
  */
  values: option<array<string>>,
  /**
  Whether a reference to a retired row of this record still resolves — the
  `@namedWhenRetired` opt-in on the `@schema type state` declaration.

  Retirement withholds a row from every door at once, which is the right answer
  to "what may this caller browse" and an unasked answer to "what is the row this
  caller is already holding a reference to called". An order names a product it
  bought; archiving the product should not unname it on the order.

  `true` opens exactly one door: a retired row answers a by-ids reference read
  with its id, its label field and the value of `field` — and nothing else, for
  any caller. It does not widen the list, the single-entity read, the index reads
  or the live frame, and it does not touch the owner rule: a retired row that is
  owner-scoped still resolves for its owner alone.

  Inside `retiredSpec` rather than beside it, because it is a rule about withheld
  rows and there are none without a retirement — the PPX errors on the annotation
  when the record declares no `@retired`, so the nesting states a guarantee rather
  than a convention.
  */
  namedWhenRetired: bool,
}

type stateAnnotationSpec = {
  ids: array<string>,
  compositeIds: array<string>,
  subIds: array<string>,
  compositeSubIds: array<string>,
  indexes: array<(string, string)>,
  hidden: array<string>,
  summary: array<string>,
  /**
  Fields annotated `@internal` — present in the record and in storage, absent
  from the generated SDL type and from the published state schema.

  A different claim from `hidden`, and the distinction is the point. `hidden`
  says "do not show this": the field is on the API and any client may ask for
  it. `internal` says "this is not on the API", so nothing can ask and nothing
  needs to be told not to show it. That is why the two are separate lists rather
  than one flag with a mode — a consumer reading `hidden` is deciding what to
  render, and a consumer reading this is deciding what exists.

  **Not a security boundary** — the same caveat `visibility` carries. It shapes
  the generated surface; `@owner` and `@retired` remain the enforcement markers.
  The PPX rejects `@internal` beside either of them, and beside every other
  marker that keys a door, because a door cannot be keyed on a field the SDL
  does not have.

  Optional so a state schema annotated by a PPX that predates the marker still
  reads: absent and empty mean the same thing to every consumer.
  */
  internal?: array<string>,
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
  Field annotated `@lifecycle` on the state record (PPX-emitted) — the enum a
  command's `@transition` is written in terms of, a board draws its columns
  from and a state diagram renders. `Some(name)` when one such annotation
  exists; the PPX errors on duplicate `@lifecycle` annotations within the same
  record. Codegen consumes this to populate `queryableDef.lifecycleField`, and
  falls back to a field literally named `"lifecycle"` whose shape is an enum
  when this annotation is absent — so a record whose field can honestly be
  called `lifecycle` declares one without ceremony.
  */
  lifecycle: option<string>,
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

  Both the boolean and the state form ride this one key. `x-reventless-retired`
  carries `value` only in the state form, on the same omit-rather-than-write-empty
  rule `label` already follows.
  */
  retired: option<retiredSpec>,
}

/** Sury metadata ID used to attach a `stateAnnotationSpec` to a state schema. */
let stateAnnotationsId: S.Metadata.Id.t<stateAnnotationSpec> =
  S.Metadata.Id.make(~namespace="reventless", ~name="stateAnnotations")

/** Returns the spec attached to a state schema, if any. */
let getSpec = (schema: S.t<unknown>): option<stateAnnotationSpec> =>
  S.Metadata.get(schema, ~id=stateAnnotationsId)
