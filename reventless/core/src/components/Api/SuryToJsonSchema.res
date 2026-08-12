// Shared utility: convert sury S.t<'a> schemas to JSON Schema objects.
// Uses SchemaType as the shared intermediate representation.

let log = Logger.fromEnv()

// ── Helpers ──────────────────────────────────────────────────────────────

let str = JSON.Encode.string

let jsonObject = (entries: array<(string, JSON.t)>): JSON.t =>
  JSON.Encode.object(Dict.fromArray(entries))

// An absent plugin means "the declaring plugin's own", which the key's absence
// says exactly. Writing an empty string instead would make "mine" and "unnamed"
// indistinguishable to every reader.
let withOptionalPlugin = (
  entries: array<(string, JSON.t)>,
  plugin: option<string>,
): array<(string, JSON.t)> =>
  switch plugin {
  | Some(p) => entries->Array.concat([("plugin", JSON.Encode.string(p))])
  | None => entries
  }

// Merge x-reventless-* extension properties from a Reventless.StateAnnotations.stateAnnotationSpec
// into a property schema (a JSON Schema object). Returns the schema unchanged when the field
// has no annotations or when the schema is not a JSON object.
let mergeAnnotations = (
  fieldSchema: JSON.t,
  fieldName: string,
  spec: Reventless.StateAnnotations.stateAnnotationSpec,
): JSON.t =>
  switch fieldSchema->JSON.Decode.object {
  | None => fieldSchema
  | Some(obj) =>
    if spec.ids->Array.includes(fieldName) {
      obj->Dict.set("x-reventless-id", JSON.Encode.bool(true))
    }
    if spec.compositeIds->Array.includes(fieldName) {
      obj->Dict.set("x-reventless-compositeId", JSON.Encode.bool(true))
    }
    if spec.subIds->Array.includes(fieldName) {
      obj->Dict.set("x-reventless-subId", JSON.Encode.bool(true))
    }
    if spec.compositeSubIds->Array.includes(fieldName) {
      obj->Dict.set("x-reventless-compositeSubId", JSON.Encode.bool(true))
    }
    switch spec.indexes->Array.find(((field, _)) => field === fieldName) {
    | Some((_, indexName)) =>
      let value =
        indexName === "" ? JSON.Encode.bool(true) : JSON.Encode.string(indexName)
      obj->Dict.set("x-reventless-index", value)
    | None => ()
    }
    if spec.hidden->Array.includes(fieldName) {
      obj->Dict.set("x-reventless-hidden", JSON.Encode.bool(true))
    }
    if spec.summary->Array.includes(fieldName) {
      obj->Dict.set("x-reventless-summary", JSON.Encode.bool(true))
    }
    switch spec.groupBy {
    | Some(name) if name === fieldName =>
      obj->Dict.set("x-reventless-group-by", JSON.Encode.bool(true))
    | _ => ()
    }
    switch spec.drillTargets->Array.find(((field, _)) => field === fieldName) {
    | Some((_, sliceName)) =>
      obj->Dict.set("x-reventless-drillTarget", JSON.Encode.string(sliceName))
    | None => ()
    }
    switch spec.drillTargetKeys->Array.find(((field, _)) => field === fieldName) {
    | Some((_, keyPath)) =>
      obj->Dict.set("x-reventless-drillTargetKey", JSON.Encode.string(keyPath))
    | None => ()
    }
    if spec.collapsed->Array.includes(fieldName) {
      obj->Dict.set("x-reventless-collapsed", JSON.Encode.bool(true))
    }
    if spec.scan->Array.includes(fieldName) {
      obj->Dict.set("x-reventless-scan", JSON.Encode.bool(true))
    }
    if spec.scanSort->Array.includes(fieldName) {
      obj->Dict.set("x-reventless-scanSort", JSON.Encode.bool(true))
    }
    switch spec.semantic->Array.find(((field, _)) => field === fieldName) {
    | Some((_, semanticId)) =>
      // The type wins. A typed declaration is better-sourced than an annotation
      // — the compiler checked it and it cannot drift from the field's shape —
      // so an annotation never overwrites one. A field carrying both is the
      // domain saying two things about one value, which is worth hearing about
      // rather than resolving in silence.
      switch obj->Dict.get("x-reventless-semantic") {
      | Some(fromType) =>
        if fromType !== JSON.Encode.string(semanticId) {
          log.warn(
            ~comp="SuryToJsonSchema",
            `field "${fieldName}" declares semantic "${semanticId}" by annotation but its type already carries ${fromType->JSON.stringify}; the type wins`,
          )
        }
      | None => obj->Dict.set("x-reventless-semantic", JSON.Encode.string(semanticId))
      }
    | None => ()
    }
    switch spec.metric->Array.find(((field, _)) => field === fieldName) {
    | Some((_, m)) =>
      // `x-reventless-metric: {aggregate, label}`. Omit an empty label so the
      // UI derives one from the field name.
      let entries = [("aggregate", JSON.Encode.string(m.aggregate))]
      let entries =
        m.label === "" ? entries : Array.concat(entries, [("label", JSON.Encode.string(m.label))])
      obj->Dict.set("x-reventless-metric", JSON.Encode.object(Dict.fromArray(entries)))
    | None => ()
    }
    JSON.Encode.object(obj)
  }

// ── SchemaType → JSON Schema ─────────────────────────────────────────────

// Whether a field's own type says it may be absent. Read through a semantic,
// which wraps the shape rather than replacing it — an optional storage ref is
// `Semantic(storageRef, Nullable(string))`.
//
// This is the half of "is it required" that `optional` cannot answer, and vice
// versa. See `objectRefToJsonSchema`, which uses both.
let rec isNullableType = (st: SchemaType.schemaType): bool =>
  switch st {
  | Nullable(_) => true
  | Semantic(_, inner) => isNullableType(inner)
  | _ => false
  }

let rec fromSchemaType = (st: SchemaType.schemaType): JSON.t =>
  switch st {
  | ScalarString => jsonObject([("type", str("string"))])
  | ScalarNumber => jsonObject([("type", str("number"))])
  | ScalarBoolean => jsonObject([("type", str("boolean"))])
  | ScalarBigInt => jsonObject([("type", str("integer"))])
  | EntityId => jsonObject([("type", str("string")), ("format", str("uuid"))])
  | DateTime => jsonObject([("type", str("string")), ("format", str("date-time"))])
  | Nullable(inner) =>
    let innerSchema = fromSchemaType(inner)
    jsonObject([("oneOf", JSON.Encode.array([innerSchema, jsonObject([("type", str("null"))])]))])
  | ArrayOf(item) =>
    jsonObject([("type", str("array")), ("items", fromSchemaType(item))])
  | ObjectRef(_, fields) => objectRefToJsonSchema(fields)
  | Enum(_, values) =>
    jsonObject([
      ("type", str("string")),
      ("enum", JSON.Encode.array(values->Array.map(JSON.Encode.string))),
    ])
  | Semantic(sem, inner) => fromSchemaType(inner)->withSemantic(sem)
  | Unknown => jsonObject([("type", str("string"))])
  }

// Attach a type-carried semantic to a field's JSON Schema.
//
// This is the type path's emission point, and it is deliberately *not*
// `mergeAnnotations`: that one is fed by the PPX-collected annotation spec,
// which the PPX only ever collects on read-model `state` records. This walk is
// schema-shape-driven and runs over every schema, commands and events included —
// which is where a declaration like a storage ref has to live, since that is
// where the value is first accepted.
//
// Both paths write the same `x-reventless-semantic` key, on purpose: one wire
// format, whatever the source. The payload rides in sibling keys so a reader
// that knows only the bare string still reads it correctly.
and withSemantic = (fieldSchema: JSON.t, sem: Reventless.Semantic.t): JSON.t =>
  switch fieldSchema->JSON.Decode.object {
  | None => fieldSchema
  | Some(obj) =>
    obj->Dict.set("x-reventless-semantic", str(sem.id))
    // The `type` discriminator is what lets a reader tell a type-carried
    // semantic from an annotated one, and rank it above the annotation
    // accordingly: the compiler checked this one, and it cannot drift from the
    // field's shape.
    obj->Dict.set("x-reventless-semantic-source", str("type"))
    switch sem.payload {
    | Plain => ()
    | ReferenceTo({entity, plugin}) =>
      obj->Dict.set(
        "x-reventless-semantic-target",
        jsonObject(withOptionalPlugin([("entity", str(entity))], plugin)),
      )
    | StoredIn({plugin, store}) =>
      // An absent plugin means "this plugin's own store" — omit the key rather
      // than writing an empty string, so a reader never has to tell those apart.
      obj->Dict.set(
        "x-reventless-semantic-target",
        jsonObject(withOptionalPlugin([("store", str(store))], plugin)),
      )
    }
    JSON.Encode.object(obj)
  }

// `optional` names the fields that may be absent; everything else is required.
// It comes from the sury schema (`SchemaType.optionalFieldNames`) rather than
// from the IR, which cannot answer for a reference or a DCB-tagged field — both
// classify as `EntityId` before the nullable wrapper is ever examined.
//
// Defaulting to "all required" mattered nowhere while only read-model state came
// through here: nothing validates a read schema. A command schema is the input
// of a form, and a field listed as required is one the form refuses to submit
// without — which turned `imageUrl?` into a picture every product had to have.
//
// `owners` arrives the same way `optional` does — a list of field names read off
// the sury schema by the caller — rather than as a case in the IR. The IR is
// shape-driven, and ownership is not a shape: it says which principal a record
// belongs to, leaving the field a plain string either way. Threading it here
// also keeps it available on command variants, which carry no annotation spec
// for `mergeAnnotations` to read.
and objectRefToJsonSchema = (
  ~annotations: option<Reventless.StateAnnotations.stateAnnotationSpec>=?,
  ~optional: array<string>=[],
  ~owners: array<string>=[],
  fields: dict<SchemaType.schemaType>,
): JSON.t => {
  let props = Dict.make()
  let required: array<string> = []
  fields
  ->Dict.toArray
  ->Array.forEach(((fieldName, fieldType)) => {
    let baseSchema = fromSchemaType(fieldType)
    let withAnnotations = switch annotations {
    | Some(spec) => mergeAnnotations(baseSchema, fieldName, spec)
    | None => baseSchema
    }
    let withAnnotations = if owners->Array.includes(fieldName) {
      switch withAnnotations->JSON.Decode.object {
      | Some(obj) =>
        obj->Dict.set("x-reventless-owner", JSON.Encode.bool(true))
        JSON.Encode.object(obj)
      | None => withAnnotations
      }
    } else {
      withAnnotations
    }
    props->Dict.set(fieldName, withAnnotations)
    // Optional two ways, because neither source answers alone. `optional` is
    // read off the sury schema and is the only thing that can speak for a
    // reference or a tagged field, which classify as `EntityId` before their
    // nullable wrapper is ever examined. But it is computed for the schema
    // handed to `deriveObjectSchema` and there is no equivalent one level in,
    // so a nested record's own optional field had nothing saying so and came
    // out *required* — a generated form refusing to submit without a field the
    // domain never asked for, which is the failure the note above describes,
    // one level down. The field's own type answers there.
    if !(optional->Array.includes(fieldName)) && !isNullableType(fieldType) {
      required->Array.push(fieldName)
    }
  })
  let entries: array<(string, JSON.t)> = [
    ("type", str("object")),
    ("properties", JSON.Encode.object(props)),
  ]
  if required->Array.length > 0 {
    entries->Array.push(("required", JSON.Encode.array(required->Array.map(JSON.Encode.string))))
  }
  jsonObject(entries)
}

// ── Public API (sury → JSON Schema via SchemaType) ───────────────────────

let deriveObjectSchema = (schema: S.t<unknown>): JSON.t =>
  switch SchemaType.fromSuryObject(~typeName="", schema) {
  | Some(fields) =>
    let annotations = Reventless.StateAnnotations.getSpec(schema)
    let objSchema = objectRefToJsonSchema(
      ~annotations?,
      ~optional=SchemaType.optionalFieldNames(schema),
      ~owners=Reventless.Owner.fieldNames(schema),
      fields,
    )
    // Surface component-level hints on the top-level object schema.
    // Visibility is omitted entirely for the default `Public` (None) so schemas
    // stay compact; live is emitted only when declared — an absent key means
    // the consumer's own default applies.
    switch annotations {
    | Some({visibility, live}) if visibility->Option.isSome || live->Option.isSome =>
      switch objSchema->JSON.Decode.object {
      | Some(obj) =>
        switch visibility {
        | Some(name) => obj->Dict.set("x-reventless-visibility", JSON.Encode.string(name))
        | None => ()
        }
        switch live {
        | Some(b) => obj->Dict.set("x-reventless-live", JSON.Encode.bool(b))
        | None => ()
        }
        JSON.Encode.object(obj)
      | None => objSchema
      }
    | _ => objSchema
    }
  | None => jsonObject([("type", str("object"))])
  }

let toJsonSchema = (schema: S.t<unknown>): JSON.t =>
  fromSchemaType(SchemaType.fromSury(~parentName="", ~fieldName="", schema))
