// GraphQL schema fragment generator.
// Derives GraphQL SDL fragments from sury schemas (commandSchema, stateSchema)
// using SchemaType as the shared intermediate representation.

open ReventlessInfra.Api

let log = Logger.fromEnv()

// Every aggregate-derived mutation returns the CommandResult union — the
// shape carries the outcome from CommandTopic processing (Accepted / Rejected
// for sync slices, Pending for async). Consumers select sub-fields via inline
// fragments. These SDL declarations are injected into any fragment that emits
// at least one mutation field; the stitcher dedupes by type name so
// concatenating across plugin + admin fragments stays safe.
let commandResultSdlTypes: array<string> = [
  `union CommandResult = CommandAccepted | CommandRejected | CommandPending`,
  `type CommandAccepted {
  msgId: ID!
  entityId: ID
  eventCount: Int!
}`,
  `type CommandRejected {
  msgId: ID!
  errorCode: String!
  errorDetail: String
}`,
  `type CommandPending {
  msgId: ID!
}`,
]

// ── SchemaType → GraphQL type reference ──────────────────────────────────────

let rec fromSchemaType = (
  ~required: bool,
  ~asInput: bool=false,
  st: SchemaType.schemaType,
  collectedTypes: array<string>,
  seenTypes: Set.t<string>,
): string => {
  let bang = required ? "!" : ""
  switch st {
  | ScalarString => `String${bang}`
  | ScalarNumber => `Float${bang}`
  | ScalarBoolean => `Boolean${bang}`
  | ScalarBigInt => `String${bang}`
  | EntityId => `ID${bang}`
  | DateTime => `String${bang}`
  | Nullable(inner) => fromSchemaType(~required=false, ~asInput, inner, collectedTypes, seenTypes)
  | ArrayOf(item) =>
    let itemType = fromSchemaType(~required=true, ~asInput, item, collectedTypes, seenTypes)
    `[${itemType}]${bang}`
  | ObjectRef(name, fields) =>
    if !(seenTypes->Set.has(name)) {
      seenTypes->Set.add(name)
      let typeDef = objectRefToGraphQL(~asInput, name, fields, collectedTypes, seenTypes)
      collectedTypes->Array.push(typeDef)
    }
    `${name}${bang}`
  | Enum(name, values) =>
    if !(seenTypes->Set.has(name)) {
      seenTypes->Set.add(name)
      let valuesStr = values->Array.join("\n  ")
      collectedTypes->Array.push(`enum ${name} {\n  ${valuesStr}\n}`)
    }
    `${name}${bang}`
  // A semantic composite is one named type rather than one per field that uses
  // it. The name comes from the semantic rather than the field path, so every
  // plugin emits a byte-identical definition — which is what lets AppSync union
  // the copies from each source API back into one, the way it already does for
  // the `Node` / `PageInfo` / `SortOrder` base types.
  //
  // GraphQL forbids one name serving as both an object and an input, so the
  // input position takes an `Input` suffix. Only these types are suffixed:
  // positionally-named objects can't collide, since their names already carry
  // the command or read model they belong to.
  | Semantic({id}, ObjectRef(name, fields)) if SchemaType.canonicalName(id)->Option.isSome =>
    let typeName = asInput ? name ++ "Input" : name
    if !(seenTypes->Set.has(typeName)) {
      seenTypes->Set.add(typeName)
      let typeDef = objectRefToGraphQL(~asInput, typeName, fields, collectedTypes, seenTypes)
      collectedTypes->Array.push(typeDef)
    }
    `${typeName}${bang}`
  // Every other semantic carries the value's shape, not its meaning: a storage
  // ref is a String on the wire exactly as it is in the event log. The semantic
  // reaches the UI through the field's JSON Schema, which is the channel that
  // can express it.
  | Semantic(_, inner) => fromSchemaType(~required, ~asInput, inner, collectedTypes, seenTypes)
  // A union declares one object type per arm and a `union` naming them. Both
  // names come from the schema — see `Reventless.TaggedUnion` — so the same union
  // is the same type wherever it appears, which is what lets AppSync merge each
  // source API's copy back into one, and what lets the write path stamp a
  // `__typename` the SDL will recognise.
  | TaggedUnion(name, arms) =>
    if asInput {
      // GraphQL has no input unions. A command that wants one takes its arms as
      // separate mutations, which is what the command decomposition already
      // does. Emitting the union type here would produce an SDL AppSync rejects
      // outright, so the field keeps the `String` it renders as today — said out
      // loud, because it is not what the declaration asks for.
      log.warn(
        ~comp="GraphQL_FragmentGenerator",
        `union "${name}" is used in an input position; GraphQL has no input unions, so the field is emitted as String. Take the arms as separate mutations instead.`,
      )
      `String${bang}`
    } else {
      if !(seenTypes->Set.has(name)) {
        seenTypes->Set.add(name)
        // The member types are collected by the recursion, which emits each arm
        // as the object type it is. `~required=false` only so the reference comes
        // back without a `!` — a union's member list carries no nullability.
        let memberNames =
          arms->Array.map(((_, armType)) =>
            fromSchemaType(~required=false, ~asInput, armType, collectedTypes, seenTypes)
          )
        collectedTypes->Array.push(`union ${name} = ${memberNames->Array.join(" | ")}`)
      }
      `${name}${bang}`
    }
  | Unknown => `String${bang}`
  }
}

and objectRefToGraphQL = (
  ~asInput: bool=false,
  typeName: string,
  fields: dict<SchemaType.schemaType>,
  collectedTypes: array<string>,
  seenTypes: Set.t<string>,
): string => {
  let fieldStrs =
    fields
    ->Dict.toArray
    ->Array.map(((fieldName, fieldType)) => {
      let gqlType = fromSchemaType(~required=true, ~asInput, fieldType, collectedTypes, seenTypes)
      `  ${fieldName}: ${gqlType}`
    })
    ->Array.join("\n")
  let keyword = asInput ? "input" : "type"
  `${keyword} ${typeName} {\n${fieldStrs}\n}`
}

// ── Legacy bridge: sury → GraphQL via SchemaType ─────────────────────────────

let deriveFieldType = (
  ~parentTypeName: string,
  ~fieldName: string,
  ~required: bool,
  fieldSchema: S.t<unknown>,
  collectedTypes: array<string>,
  seenTypes: Set.t<string>,
): string => {
  let st = SchemaType.fromSury(~parentName=parentTypeName, ~fieldName, fieldSchema)
  fromSchemaType(~required, st, collectedTypes, seenTypes)
}

// ── Object type derivation ─────────────────────────────────────────────────

// A union field the walk cannot classify is emitted as `String`, and that has
// been true and silent for as long as the fallthrough has existed. Saying it here
// — at the one point every generated object type is derived — costs a walk of the
// schema and turns a field that will fail at execution into a line in the deploy
// log naming the type and the field.
let reportUnclassifiedUnions = (~typeName: string, schema: S.t<unknown>): unit =>
  SchemaType.unclassifiedUnions(schema)->Array.forEach(({path, reason}) =>
    log.warn(
      ~comp="GraphQL_FragmentGenerator",
      `${typeName}.${path} is emitted as String: ${reason}`,
    )
  )

// The SDL line for one `@resolves` / `@resolvesMany` field. Both forms are
// nullable: the single form has no row when the foreign key names one that was
// never written, and the batch form drops missing ids rather than padding with
// nulls, so the list is shorter — never null inside.
let resolvedFieldSdl = ({fieldName, typeName, multi}: resolvedFieldEntry): string =>
  multi ? `  ${fieldName}: [${typeName}!]` : `  ${fieldName}: ${typeName}`

let deriveObjectTypeWithNested = (
  ~typeName: string,
  ~excludeFields: array<string>=[],
  ~includeIdParam: bool=true,
  ~resolvedFields: array<resolvedFieldEntry>=[],
  schema: S.t<unknown>,
): array<string> => {
  reportUnclassifiedUnions(~typeName, schema)
  switch SchemaType.fromSuryObject(~typeName, schema) {
  | Some(fields) =>
    // `@internal` joins the caller's exclusions rather than replacing them. The
    // caller's list is a decision made where the query entry is assembled; this
    // one is a declaration on the field itself, and the schema is the better
    // place for it — a hand-written list has to be kept in step with the record
    // by whoever next edits it, which is the drift that made a hand-maintained
    // `pluginExcludeFields` necessary in the first place.
    //
    // This is the single point for the SDL: every generated object type is
    // derived here, so a field declared internal is absent from all of them
    // without any entry having to say so.
    let declaredInternal =
      Reventless.StateAnnotations.getSpec(schema)
      ->Option.flatMap(spec => spec.internal)
      ->Option.getOr([])
    let excludeFields = Array.concat(excludeFields, declaredInternal)
    let filteredFields = if excludeFields->Array.length > 0 {
      let d = Dict.make()
      fields
      ->Dict.toArray
      ->Array.forEach(((k, v)) => {
        if !(excludeFields->Array.some(ex => ex == k)) {
          d->Dict.set(k, v)
        }
      })
      d
    } else {
      fields
    }
    let collectedTypes: array<string> = []
    let seenTypes = Set.make()
    seenTypes->Set.add(typeName)
    let mainType = objectRefToGraphQL(typeName, filteredFields, collectedTypes, seenTypes)
    let mainTypeWithId = if includeIdParam {
      mainType->String.replace(
        `type ${typeName} {\n`,
        `type ${typeName} implements Node {\n  id: ID!\n`,
      )
    } else {
      mainType
    }
    // A cross-table field shares the type with the state record's own fields, so
    // a name already taken would emit the field twice and fail the whole document
    // — for every plugin in the merge, not just this one. Refuse at build time,
    // naming both halves.
    resolvedFields->Array.forEach(({fieldName}) =>
      if filteredFields->Dict.get(fieldName)->Option.isSome || (includeIdParam && fieldName == "id") {
        JsError.throwWithMessage(
          `${typeName}.${fieldName} is declared by @resolves/@resolvesMany and is already a field of the state record. Name the resolved field something the state does not use.`,
        )
      }
    )
    let mainTypeComplete = if resolvedFields->Array.length == 0 {
      mainTypeWithId
    } else {
      let body = mainTypeWithId->String.slice(~start=0, ~end=mainTypeWithId->String.length - 1)
      body ++ resolvedFields->Array.map(resolvedFieldSdl)->Array.join("\n") ++ "\n}"
    }
    Array.concat(collectedTypes, [mainTypeComplete])
  | None => []
  }
}

let derivePluralWrapperType = (~pluralTypeName: string, ~singularTypeName: string): string =>
  `type ${pluralTypeName} {\n  nextToken: String\n  scannedCount: Int!\n  items: [${singularTypeName}!]!\n}`

let deriveConnectionTypes = (~singularTypeName: string): array<string> => [
  `type ${singularTypeName}Edge {\n  node: ${singularTypeName}!\n  cursor: String!\n}`,
  `type ${singularTypeName}Connection {\n  edges: [${singularTypeName}Edge!]!\n  pageInfo: PageInfo!\n}`,
]

let deriveSubIdFilterType = (~filterTypeName: string): string =>
  `input ${filterTypeName} {\n  prefix: String\n  from: String\n  to: String\n  eq: String\n  order: SortOrder\n}`

// ── Server-side filter / sort capability ─────────────────────────────────────
// Derived from the structural annotations carried on the state schema
// (`@id`, `@compositeId`, `@subId`, `@compositeSubId`, `@index`). Both the
// SDL emitter and the in-memory resolver consume the same record so the
// emitted Filter / OrderBy and the runtime narrow / sort cannot drift.

type filterField = {
  name: string,
  gqlType: string,
  range: bool,
}

type serverCapability = {
  filterFields: array<filterField>,
  sortFields: array<string>,
}

let emptyCapability: serverCapability = {filterFields: [], sortFields: []}

// Convert a SchemaType.schemaType to its GraphQL scalar name (input position).
// Mirrors the scalar branches of fromSchemaType — kept inline because we don't
// emit `!`/list wrappers for filter inputs.
let rec scalarOfSchemaType = (st: SchemaType.schemaType): string =>
  switch st {
  | ScalarString => "String"
  | ScalarNumber => "Float"
  | ScalarBoolean => "Boolean"
  | ScalarBigInt => "String"
  | EntityId => "ID"
  | Semantic(_, inner) => scalarOfSchemaType(inner)
  | _ => "String"
  }

// A `*Id`-suffixed field name, case-sensitively. Deliberately NOT
// `SchemaType.isIdFieldName`, which lowercases before testing the suffix and so
// accepts `paid` and `valid` — harmless where it is used, but here it would
// nominate an ordinary word as a row's key.
let isKeyFieldName = (name: string): bool =>
  name->String.length > 2 && name->String.endsWith("Id")

/**
The field that identifies a row, and which rung answered:

- `"annotation"` — the state declares `@id`. Nothing outranks it.
- `"convention"` — a field named `<singular entity name>Id` exists
  (`Products` → `productId`). A guess, but one that can only fire on a field
  that is actually there.
- `"sole"` — the state has exactly one `*Id` field, so there is nothing else it
  could be (`AvailableProducts` → `productId`).

`None` is the honest answer for a state with several `*Id` fields and no name
match (`ProductDemand`: `productId` + `categoryId`), or with none at all — those
need `@id`. Convention outranks sole so a view carrying one foreign key and no
key of its own is not keyed by the foreign key.
*/
let resolveKeyField = (~entityName: string, schema: S.t<unknown>): option<(string, string)> => {
  let declared = switch Reventless.StateAnnotations.getSpec(schema) {
  | Some({ids}) => ids->Array.get(0)
  | None => None
  }
  switch declared {
  | Some(field) => Some((field, "annotation"))
  | None =>
    let candidates =
      SchemaType.fromSuryObject(~typeName="", schema)
      ->Option.getOr(Dict.make())
      ->Dict.keysToArray
      ->Array.filter(isKeyFieldName)
    let singular = entityName->Api_Naming.stripViewSuffix->Api_Naming.singularize
    let conventional =
      singular->String.slice(~start=0, ~end=1)->String.toLowerCase ++
      singular->String.slice(~start=1, ~end=singular->String.length) ++ "Id"
    if candidates->Array.includes(conventional) {
      Some((conventional, "convention"))
    } else if candidates->Array.length == 1 {
      Some((candidates->Array.getUnsafe(0), "sole"))
    } else {
      None
    }
  }
}

// The component name the key-field convention is read against. `specName` is the
// read model's own `Spec.name`; without it, `returnTypeName` minus its plugin
// prefix is the same string (`Catalog_Product` → `Product`).
let entityNameOf = (entry: ReventlessInfra.Api.querySchemaEntry): string =>
  switch entry.specName {
  | Some(n) => n
  | None =>
    switch entry.returnTypeName->String.lastIndexOf("_") {
    | -1 => entry.returnTypeName
    | i =>
      entry.returnTypeName->String.slice(~start=i + 1, ~end=entry.returnTypeName->String.length)
    }
  }

let deriveServerCapability = (~entityName: string, schema: S.t<unknown>): serverCapability => {
  let fieldTypes = SchemaType.fromSuryObject(~typeName="", schema)->Option.getOr(Dict.make())
  let scalarOf = (fieldName: string): string =>
    fieldTypes->Dict.get(fieldName)->Option.mapOr("String", scalarOfSchemaType)

  let filterFields: array<filterField> = []
  let sortFields: array<string> = []
  let seenFilter: Set.t<string> = Set.make()
  let seenSort: Set.t<string> = Set.make()

  let pushFilter = (name, ~range) =>
    if !(seenFilter->Set.has(name)) {
      seenFilter->Set.add(name)
      filterFields->Array.push({name, gqlType: scalarOf(name), range})
    }
  let pushSort = name =>
    if !(seenSort->Set.has(name)) {
      seenSort->Set.add(name)
      sortFields->Array.push(name)
    }

  switch Reventless.StateAnnotations.getSpec(schema) {
  | None => ()
  | Some(spec) =>
    spec.ids->Array.forEach(name => {
      pushFilter(name, ~range=false)
      pushSort(name)
    })
    spec.compositeIds->Array.forEach(name => pushFilter(name, ~range=false))
    spec.subIds->Array.forEach(name => {
      pushFilter(name, ~range=true)
      pushSort(name)
    })
    spec.compositeSubIds->Array.forEach(name => {
      pushFilter(name, ~range=true)
      pushSort(name)
    })
    spec.indexes->Array.forEach(((name, _indexName)) => {
      pushFilter(name, ~range=false)
      pushSort(name)
    })
    // @scan / @scanSort are explicit opt-ins for non-indexed fields. They
    // expand the SDL surface only — the in-memory resolver's narrow / sort
    // helpers already operate on arbitrary fields, so no additional code
    // path is needed here.
    spec.scan->Array.forEach(name => pushFilter(name, ~range=false))
    spec.scanSort->Array.forEach(name => pushSort(name))
  }

  // A state that declares nothing structural used to land here with an empty
  // capability — no per-field filter and no order-by at all, so every narrowing
  // a client asked for happened client-side over one page. Its key is knowable
  // without the annotation in the common cases; take it. Pushed last, and both
  // pushes dedupe, so a declared `@id` keeps its position and this is a no-op.
  switch resolveKeyField(~entityName, schema) {
  | Some((field, _rung)) =>
    pushFilter(field, ~range=false)
    pushSort(field)
  | None => ()
  }

  {filterFields, sortFields}
}

// Returns one warning per `@scanSort` field that is NOT also a sort key of the
// table or any GSI. The Scan-based AWS resolver evaluates such requests as a
// JS-runtime per-page sort over a full Scan — correct, but expensive. The
// schema author should either point the field at an index sort key or
// explicitly accept the per-page-sort caveat. Returns [] when validation is
// not applicable (no schema, no `@scanSort` fields).
let validateScanSortAlignment = (
  ~schema: S.t<unknown>,
  ~readModelName: string,
  ~knownSortFields: array<string>,
): array<string> =>
  switch Reventless.StateAnnotations.getSpec(schema) {
  | None => []
  | Some(spec) =>
    spec.scanSort->Array.filterMap(field =>
      if knownSortFields->Array.includes(field) {
        None
      } else {
        Some(
          `Read model "${readModelName}": @scanSort field "${field}" is not the sort key of any table or GSI. Sort requests Scan the whole table and sort per-page, so results past the first page are NOT globally ordered — and the Scan is expensive in production. Promote the field to an index sort key for correct, cheap ordering, or accept per-page ordering.`,
        )
      }
    )
  }

let deriveConnectionFilterType = (
  ~filterTypeName: string,
  ~capability: serverCapability=emptyCapability,
): string => {
  let baseFields = ["search: String", "searchPrefix: String", "ids: [ID!]"]
  let perFieldFilters =
    capability.filterFields->Array.flatMap(f => {
      let eq = `${f.name}Eq: ${f.gqlType}`
      if f.range {
        [eq, `${f.name}From: ${f.gqlType}`, `${f.name}To: ${f.gqlType}`]
      } else {
        [eq]
      }
    })
  let allFields = Array.concat(baseFields, perFieldFilters)
  let body = allFields->Array.map(f => `  ${f}`)->Array.join("\n")
  `input ${filterTypeName} {\n${body}\n}`
}

// Emits an `enum <Type>OrderField` and `input <Type>OrderBy` pair when the
// capability has any sort fields. Returns [] when no field is sortable so
// the connection field doesn't reference a non-existent OrderBy type.
let deriveConnectionOrderByType = (
  ~singularTypeName: string,
  ~capability: serverCapability,
): array<string> =>
  if capability.sortFields->Array.length == 0 {
    []
  } else {
    let orderFieldEnumName = singularTypeName ++ "OrderField"
    let orderByInputName = singularTypeName ++ "OrderBy"
    let valuesStr = capability.sortFields->Array.map(f => `  ${f}`)->Array.join("\n")
    [
      `enum ${orderFieldEnumName} {\n${valuesStr}\n}`,
      `input ${orderByInputName} {\n  field: ${orderFieldEnumName}!\n  direction: SortOrder!\n}`,
    ]
  }

let deriveItemsQueryField = (
  ~singleFieldName: string,
  ~returnTypeName: string,
  ~filterTypeName: string,
): string =>
  `  ${singleFieldName}Items(id: ID!, filter: ${filterTypeName}, first: Int, after: String, last: Int, before: String): ${returnTypeName}Connection!`

// ── Query field derivation ─────────────────────────────────────────────────

let deriveObjectQueryField = (
  ~singleFieldName: string,
  ~typeName: string,
  ~includeIdParam: bool=true,
  ~subIdField: option<string>=?,
): string =>
  if includeIdParam {
    // `includeRetired` reaches this door for the reason it reaches the list: a
    // caller the server would serve a retired row to had, until it did, no way
    // to ask for one *singly*. The archive toggle put such rows on screen and
    // clicking one read a door that refuses them to everybody — `decideRetired`
    // withholds from `Elevated` and `System` too until they ask, and here there
    // was nothing to ask with.
    switch subIdField {
    | Some(sortField) =>
      `  ${singleFieldName}(id: ID!, ${sortField}: String!, includeRetired: Boolean): ${typeName}`
    | None => `  ${singleFieldName}(id: ID!, includeRetired: Boolean): ${typeName}`
    }
  } else {
    `  ${singleFieldName}: ${typeName}`
  }

let deriveListQueryField = (
  ~listFieldName: string,
  ~pluralTypeName: string,
): string =>
  `  ${listFieldName}(nextToken: String, limit: Int): ${pluralTypeName}!`

// Batched-by-ids query: fetches multiple entities in a single BatchGetItem.
// Cardinality is not preserved (missing ids drop out of the response), so the
// caller correlates by `id` on each returned item. Single-key tables only —
// composite-key BatchGetItem requires both pk + sk per key entry, which is
// out of scope for this field.
let deriveByIdsQueryField = (
  ~listFieldName: string,
  ~returnTypeName: string,
): string =>
  `  ${listFieldName}ByIds(ids: [String!]!, includeRetired: Boolean): [${returnTypeName}!]!`

// ── The reference door ─────────────────────────────────────────────────────
//
// What a caller holding a pointer to a row may learn about it: its id, the label
// a reference resolves to, and — where the view declares a retirement — whether
// this row is in one and which state that is.
//
// The narrowness is the *type's*, which is the whole reason this is a separate
// field rather than an argument on the by-ids door. A rule that answered a
// retired row on the existing door "as long as only the safe fields were asked
// for" would have to be re-implemented, identically, in four backends and to
// survive aliases, fragments and `__typename`. Here a caller cannot ask for a
// price, because the type has no price.
//
// Emitted for every view, not only for the ones that opted in, on exactly the
// reasoning `includeRetired` states above: a field that appears and disappears
// with an annotation makes adding or removing that annotation a breaking schema
// change, and forces every client to feature-detect. What the annotation decides
// is not whether the door exists but whether a *retired* row comes through it —
// without it this is a cheap label read that narrows exactly as every other door
// does.
let deriveRefTypeSdl = (~returnTypeName: string): string =>
  `type ${returnTypeName}Ref {\n  id: ID!\n  label: String!\n  retired: Boolean!\n  retiredState: String\n}`

// `retiredState` is null in two cases that do not need telling apart by a
// consumer: a live row, and a boolean-form retirement, where the field is the
// state and `retired: true` has already said everything there is to say.
let deriveRefsQueryField = (
  ~listFieldName: string,
  ~returnTypeName: string,
): string => `  ${listFieldName}Refs(ids: [ID!]!): [${returnTypeName}Ref!]!`

// `includeRetired` sits beside the paging arguments rather than inside `filter`,
// and that placement is the point. `filter` is the caller's description of the
// rows they want; this is a request to lift a restriction the server placed on
// them, which the server grants or ignores on its own terms. Putting it in the
// filter input would also require the field to be a declared filter field, which
// would publish `<field>Eq` to callers who can only ever get an empty page from
// it.
//
// Emitted unconditionally, on every connection field, whether or not the view
// declares a retirement flag. A view that declares none ignores it, and the
// alternative — an argument that appears and disappears with the annotation —
// makes adding `@retired` a breaking schema change for every client that had
// already learned the field's shape.
let deriveConnectionQueryField = (
  ~listFieldName: string,
  ~singularTypeName: string,
  ~filterTypeName: string,
  ~hasOrderBy: bool=false,
): string => {
  let orderByArg = hasOrderBy ? `, orderBy: ${singularTypeName}OrderBy` : ""
  `  ${listFieldName}(filter: ${filterTypeName}${orderByArg}, first: Int, after: String, last: Int, before: String, includeRetired: Boolean): ${singularTypeName}Connection!`
}

// ── The by-index door ──────────────────────────────────────────────────────
//
// One derivation, called by every backend that serves this field, because the
// alternative was tried and did not survive contact. The field used to be
// emitted here for AppSync and again, independently, in the local adapter, and
// the two agreed on neither its name, its argument nor its return type. Both
// were wrong in the same way: each disagreed with the resolver standing behind
// it. The AppSync shape declared `id: ID!` while its resolver read the index
// field, so the value could not be passed at all; the local shape promised
// `[String]` while its resolver returned whole rows, so every call failed to
// serialise. A door that answers on no backend is a door whose signature can be
// chosen on the merits, which is what the one below is.

/** The row field an index is keyed on.

For a named index (`@index("byOwner") ownerId`) the index name and the field it
indexes differ, and it is the *field* every resolver filters on; for an unnamed
index the two are the same string. */
let indexKeyField = (indexConfig: Reventless.ReadModel.indexConfig): string =>
  indexConfig.idField->Option.getOr(indexConfig.index)

/** `<single>By<Index>`, dropping a leading `by` from the index name so
`@index("byOwner")` reads `XByOwner` rather than `XByByOwner`. */
let indexQueryFieldName = (~singleFieldName: string, ~index: string): string => {
  let stripped = if index->String.startsWith("by") && index->String.length > 2 {
    index->String.slice(~start=2, ~end=index->String.length)
  } else {
    index
  }
  singleFieldName ++ "By" ++ stripped->String.capitalize
}

/** The by-index door's signature.

Paging and `includeRetired` are here for the reasons `deriveConnectionQueryField`
gives above — this door reads a secondary index that can carry as many rows as
the list, and an elevated caller that can widen every other door but this one
would find the archive reachable by id and by list and not by the index that
exists to look rows up. */
let deriveIndexQueryField = (
  ~singleFieldName: string,
  ~indexConfig: Reventless.ReadModel.indexConfig,
  ~connectionTypeName: string,
): string => {
  let fieldName = indexQueryFieldName(~singleFieldName, ~index=indexConfig.index)
  let keyField = indexKeyField(indexConfig)
  // An index with a sort key can be narrowed to one exact value on it. Optional,
  // unlike the partition argument: naming the index value is what the door is
  // for, narrowing further is a refinement. The AppSync sort template has read
  // this argument all along, against an SDL that never offered it.
  let sortArg = switch indexConfig.subIdField {
  | Some(sortField) => `${sortField}: String, `
  | None => ""
  }
  `  ${fieldName}(${keyField}: String!, ${sortArg}first: Int, after: String, last: Int, before: String, includeRetired: Boolean): ${connectionTypeName}!`
}

// ── Mutation field derivation ──────────────────────────────────────────────

let deriveMutationFieldFromObject = (
  ~fieldName: string,
  ~collectedTypes: array<string>,
  ~seenTypes: Set.t<string>,
  variantSchema: S.t<unknown>,
): option<string> =>
  switch SchemaType.fromSuryObject(~typeName=fieldName, variantSchema) {
  | Some(fields) =>
    let args =
      fields
      ->Dict.toArray
      ->Array.map(((argName, argType)) => {
        let gqlType = fromSchemaType(
          ~required=true,
          ~asInput=true,
          argType,
          collectedTypes,
          seenTypes,
        )
        `${argName}: ${gqlType}`
      })
      ->Array.join(", ")
    let argsPart = args->String.length > 0 ? `(${args})` : ""
    Some(`  ${fieldName}${argsPart}: CommandResult!`)
  | None => None
  }

// The rendered GraphQL type of every argument one mutation field declares,
// keyed by argument name — `"Ordering_PlaceOrderShippingMethod!"`,
// `"DateRangeInput"`, `"[Ordering_PlaceOrderLineItems!]!"`.
//
// A client that assembles its own mutation document must declare a variable per
// argument, and it cannot derive these from JSON Schema: an enum's type name is
// composed from the mutation field and the property, an object's comes from a
// semantic or the field path, and the nullability comes from whether the sury
// schema wrapped it in an option. None of that survives the JSON-Schema
// projection, so the name is published rather than left to be re-derived from a
// convention that would then live in two repos shipping on different cycles.
//
// Deliberately the same `fromSchemaType` call `deriveMutationFieldFromObject`
// makes: one producer, so the published string and the SDL cannot disagree.
// The collected type *definitions* are discarded — a caller wants the reference
// each argument renders as, and the definitions are already in the schema this
// generator emits.
let mutationArgTypes = (~fieldName: string, variantSchema: S.t<unknown>): option<dict<string>> =>
  SchemaType.fromSuryObject(~typeName=fieldName, variantSchema)->Option.map(fields => {
    let out = Dict.make()
    fields
    ->Dict.toArray
    ->Array.forEach(((argName, argType)) =>
      out->Dict.set(
        argName,
        fromSchemaType(~required=true, ~asInput=true, argType, [], Set.make()),
      )
    )
    out
  })

// ── Main generate function ─────────────────────────────────────────────────

let generate = (
  ~mutationEntries: array<mutationSchemaEntry>,
  ~queryEntries: array<querySchemaEntry>,
): Reventless.Plugin.apiSchemaFragment => {
  let types: array<string> = []
  let mutations: array<string> = []
  let queries: array<string> = []
  let seenTypes = Set.make()

  // Extract the constructor name from a mutation field name like
  // `Plugin_Activate` / `Platform_Plugin_Activate` — always the last
  // underscore-separated segment (e.g. `Activate`).
  let constructorNameOf = (fieldName: string): string =>
    fieldName->String.split("_")->Array.get(fieldName->String.split("_")->Array.length - 1)
      ->Option.getOr(fieldName)

  mutationEntries->Array.forEach(entry => {
    let schema = entry.commandSchema
    // Aggregates carry the instance id as a separate `id: ID!` argument ahead of
    // the command payload; DCB slices don't (their key field is part of the
    // payload). A multi-variant slice command is a sury `Union` just like an
    // aggregate command, so the injection must key off the entry flag, not the
    // schema shape — see `mutationSchemaEntry.injectIdArg`.
    let injectIdArg = entry.injectIdArg->Option.getOr(true)
    switch schema {
    | AnyOf({anyOf}) =>
      // Map each fieldName to its variant in anyOf by matching the constructor
      // name. Position-based pairing (anyOf index ↔ fieldNames index) breaks
      // when `@noApi` filters out some variants but the schema still carries
      // them — the field name "Platform_Plugin_Deactivate" would otherwise be
      // married to the `Connect(pluginDefinition)` variant at unfiltered
      // index 1, leaking a stale `_0: Platform_Plugin_Deactivate_0` arg.
      let variantNames = anyOf->Array.map(v =>
        switch v {
        | Object({properties}) => SchemaWalker.tagConstOf(properties)->Option.getOr("")
        | String({const: ?Some(const)}) => const
        | _ => ""
        }
      )
      entry.fieldNames->Array.forEach(fieldName => {
        let cname = constructorNameOf(fieldName)
        let variantIndex = variantNames->Array.indexOf(cname)
        let variantSchema = variantIndex >= 0
          ? anyOf->Array.get(variantIndex)->Option.getOr(schema)
          : schema
        switch deriveMutationFieldFromObject(
          ~fieldName,
          ~collectedTypes=types,
          ~seenTypes,
          variantSchema,
        ) {
        | Some(field) =>
          let withId = if !injectIdArg {
            field
          } else if field->String.includes("(") {
            field->String.replace(`${fieldName}(`, `${fieldName}(id: ID!, `)
          } else {
            field->String.replace(`${fieldName}:`, `${fieldName}(id: ID!):`)
          }
          mutations->Array.push(withId)
        | None =>
          // Payload-less variant (S.literal("Ctor")) — no Object fields to
          // derive args from, but still a valid mutation.
          let field = injectIdArg
            ? `  ${fieldName}(id: ID!): CommandResult!`
            : `  ${fieldName}: CommandResult!`
          mutations->Array.push(field)
        }
      })
    | Object(_) =>
      let fieldName = entry.fieldNames->Array.get(0)->Option.getOr("")
      if fieldName->String.length > 0 {
        deriveMutationFieldFromObject(
          ~fieldName,
          ~collectedTypes=types,
          ~seenTypes,
          schema,
        )
        ->Option.forEach(field => mutations->Array.push(field))
      }
    | _ => ()
    }
  })

  // Two things a cross-table field has to satisfy, both checked before anything
  // is emitted so the report names the declaration rather than the merge:
  //
  // The type it returns has to be one this fragment defines. A plugin's document
  // is validated standalone before it is merged, and a field returning a name
  // nothing declares fails the whole document rather than just the field.
  //
  // And the target has to be guarded the way the parent is. A nested field is
  // reached through its parent, so it answers under the parent's authorization —
  // a target that guards itself differently would be handed over by the wider
  // door, which is the kind of hole nothing downstream can see. Equal rules pass,
  // and so does a target open to everyone, which can only narrow.
  let permissionOf = (entry: querySchemaEntry) =>
    entry.permission->Option.getOr(Reventless.Authorization.AllowAuthenticated)
  queryEntries->Array.forEach(entry =>
    entry.resolvedFields
    ->Option.getOr([])
    ->Array.forEach(({fieldName, typeName}) =>
      switch queryEntries->Array.find(e => e.returnTypeName == typeName) {
      | None =>
        JsError.throwWithMessage(
          `${entry.returnTypeName}.${fieldName} is declared by @resolves/@resolvesMany and resolves to "${typeName}", which this plugin does not expose as a queryable. The target must be a ReadModel or StateViewSlice of the same plugin, named by its spec name.`,
        )
      | Some(target) =>
        let targetPermission = permissionOf(target)
        if targetPermission != permissionOf(entry) && targetPermission != AllowAnonymous {
          JsError.throwWithMessage(
            `${entry.returnTypeName}.${fieldName} resolves to "${typeName}", which declares a different authorization. A cross-table field is read through its parent and would answer under ${entry.returnTypeName}'s rule, handing over rows ${typeName}'s own door withholds. Give the two views the same authorization, or query ${typeName} directly.`,
          )
        }
      }
    )
  )

  queryEntries->Array.forEach(entry => {
    let includeIdParam = entry.includeIdParam->Option.getOr(true)
    let connectionSpec = entry.connectionSpec->Option.getOr(true)
    if !(seenTypes->Set.has(entry.returnTypeName)) {
      seenTypes->Set.add(entry.returnTypeName)
      let excludeFields = switch entry.excludeFields {
      | Some(fields) => fields
      | None => []
      }
      let nestedTypes = deriveObjectTypeWithNested(
        ~typeName=entry.returnTypeName,
        ~excludeFields,
        ~includeIdParam,
        ~resolvedFields=entry.resolvedFields->Option.getOr([]),
        entry.stateSchema,
      )
      nestedTypes->Array.forEach(t => {
        types->Array.push(t)
      })
    }

    let singleField = deriveObjectQueryField(
      ~singleFieldName=entry.singleFieldName,
      ~typeName=entry.returnTypeName,
      ~includeIdParam,
      ~subIdField=?entry.subIdField,
    )
    queries->Array.push(singleField)

    // Batched-by-ids field for single-key projections (subIdField=None).
    // Skipped for composite-key projections — BatchGetItem requires both
    // partition + sort attributes per key entry.
    if includeIdParam && entry.subIdField === None {
      queries->Array.push(
        deriveByIdsQueryField(
          ~listFieldName=entry.listFieldName,
          ~returnTypeName=entry.returnTypeName,
        ),
      )

      // The reference door, under the by-ids condition because it is the same
      // read. Emitted here rather than per-backend so the field a backend
      // provisions a resolver for is one this SDL declares: the AppSync adapter
      // registers `<list>Refs` for every queryable on exactly that premise, and
      // a door named in one half and not the other fails the deploy outright.
      let refTypeName = entry.returnTypeName ++ "Ref"
      if !(seenTypes->Set.has(refTypeName)) {
        seenTypes->Set.add(refTypeName)
        types->Array.push(deriveRefTypeSdl(~returnTypeName=entry.returnTypeName))
      }
      queries->Array.push(
        deriveRefsQueryField(
          ~listFieldName=entry.listFieldName,
          ~returnTypeName=entry.returnTypeName,
        ),
      )
    }

    let listFieldName = entry.listFieldName
    // Items query (sort key conditions, Relay connection) — generated when subIdField is set
    switch entry.subIdField {
    | Some(_sf) =>
      let itemsFilterTypeName = entry.returnTypeName ++ "ItemsFilter"
      if !(seenTypes->Set.has(itemsFilterTypeName)) {
        seenTypes->Set.add(itemsFilterTypeName)
        types->Array.push(deriveSubIdFilterType(~filterTypeName=itemsFilterTypeName))
      }
      queries->Array.push(
        deriveItemsQueryField(
          ~singleFieldName=entry.singleFieldName,
          ~returnTypeName=entry.returnTypeName,
          ~filterTypeName=itemsFilterTypeName,
        ),
      )
    | None => ()
    }

    // By-index connection queries — generated for each GSI on the entry
    switch entry.indexQueries {
    | Some(indexes) =>
      let connectionTypeName = entry.returnTypeName ++ "Connection"
      indexes->Array.forEach(indexConfig =>
        queries->Array.push(
          deriveIndexQueryField(
            ~singleFieldName=entry.singleFieldName,
            ~indexConfig,
            ~connectionTypeName,
          ),
        )
      )
    | None => ()
    }

    if connectionSpec {
      // Relay Connection spec: Edge + Connection types
      let connectionTypeName = entry.returnTypeName ++ "Connection"
      if !(seenTypes->Set.has(connectionTypeName)) {
        let edgeName = entry.returnTypeName ++ "Edge"
        seenTypes->Set.add(edgeName)
        seenTypes->Set.add(connectionTypeName)
        deriveConnectionTypes(~singularTypeName=entry.returnTypeName)
        ->Array.forEach(t => types->Array.push(t))
      }
      let capability = deriveServerCapability(~entityName=entityNameOf(entry), entry.stateSchema)
      let connectionFilterTypeName = entry.returnTypeName ++ "Filter"
      if !(seenTypes->Set.has(connectionFilterTypeName)) {
        seenTypes->Set.add(connectionFilterTypeName)
        types->Array.push(
          deriveConnectionFilterType(~filterTypeName=connectionFilterTypeName, ~capability),
        )
      }
      let orderByTypes =
        deriveConnectionOrderByType(~singularTypeName=entry.returnTypeName, ~capability)
      let hasOrderBy = orderByTypes->Array.length > 0
      if hasOrderBy {
        let orderFieldEnumName = entry.returnTypeName ++ "OrderField"
        let orderByInputName = entry.returnTypeName ++ "OrderBy"
        if !(seenTypes->Set.has(orderFieldEnumName)) {
          seenTypes->Set.add(orderFieldEnumName)
          seenTypes->Set.add(orderByInputName)
          orderByTypes->Array.forEach(t => types->Array.push(t))
        }
      }
      let listField = deriveConnectionQueryField(
        ~listFieldName,
        ~singularTypeName=entry.returnTypeName,
        ~filterTypeName=connectionFilterTypeName,
        ~hasOrderBy,
      )
      queries->Array.push(listField)
    } else {
      // Legacy AppSync-style: items/nextToken/scannedCount
      if !(seenTypes->Set.has(listFieldName)) {
        seenTypes->Set.add(listFieldName)
        let pluralType = derivePluralWrapperType(
          ~pluralTypeName=listFieldName,
          ~singularTypeName=entry.returnTypeName,
        )
        types->Array.push(pluralType)
      }
      let listField = deriveListQueryField(
        ~listFieldName,
        ~pluralTypeName=listFieldName,
      )
      queries->Array.push(listField)
    }
  })

  // If any mutation fields were emitted, every one of them returns
  // `CommandResult!` — inject the union + 3 outcome types so the fragment is
  // self-contained. Stitcher dedupes by type name across fragments.
  if mutations->Array.length > 0 {
    commandResultSdlTypes->Array.forEach(t => types->Array.push(t))
  }

  GraphQL_Stitcher.encode({
    types,
    mutations,
    queries,
    subscriptions: [],
    subscriptionSources: [],
  })
}
