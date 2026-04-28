/**
Spec describing the structural annotations declared on the fields of an
`@schema type state` record. The ppx attaches one of these to the generated
`stateSchema` whenever a field carries `@id`, `@compositeId`, `@subId`,
`@compositeSubId`, or `@index`. Downstream consumers (UI, MCP, codegen) read
the spec to surface field roles in JSON Schema as `x-reventless-*` extension
properties.

Each list contains the source field names; `indexes` carries `(fieldName,
indexName)` pairs where `indexName` is `""` for unnamed `@index` annotations.
*/
type stateAnnotationSpec = {
  ids: array<string>,
  compositeIds: array<string>,
  subIds: array<string>,
  compositeSubIds: array<string>,
  indexes: array<(string, string)>,
}

/** Sury metadata ID used to attach a `stateAnnotationSpec` to a state schema. */
let stateAnnotationsId: S.Metadata.Id.t<stateAnnotationSpec> =
  S.Metadata.Id.make(~namespace="reventless", ~name="stateAnnotations")

/** Returns the spec attached to a state schema, if any. */
let getSpec = (schema: S.t<unknown>): option<stateAnnotationSpec> =>
  S.Metadata.get(schema, ~id=stateAnnotationsId)
