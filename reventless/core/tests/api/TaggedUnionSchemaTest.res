open JestGlobals
open TaggedUnionFixtures

let fragmentFor = (~returnTypeName, ~specName, stateSchema) =>
  GraphQL_FragmentGenerator.generate(
    ~mutationEntries=[],
    ~queryEntries=[queryEntryFor(~returnTypeName, ~specName, stateSchema)],
  )

let typesOf = fragment => GraphQL_Stitcher.decode(fragment).types
let typeDefFor = (fragment, needle) =>
  typesOf(fragment)->Array.find(t => t->String.includes(needle))->Option.getOr("")

// ── The IR ────────────────────────────────────────────────────────────────

describe("SchemaType classifies a named union", () => {
  let shapeOfField = (schema, field) =>
    switch SchemaType.fromSuryObject(~typeName="X", schema->S.castToUnknown) {
    | Some(fields) => fields->Dict.get(field)
    | None => None
    }

  testSync("arms are keyed by TAG and carry the member type's own name", () => {
    switch shapeOfField(CustomersSpec.stateSchema, "geolocation") {
    | Some(TaggedUnion(name, arms)) =>
      expect(name)->toBe("Geolocation")
      expect(arms->Array.map(((tag, _)) => tag))->toEqual(["Pending", "Located", "Unresolvable"])
      switch arms->Array.find(((tag, _)) => tag === "Located") {
      | Some((_, ObjectRef(memberName, fields))) =>
        expect(memberName)->toBe("GeolocationLocated")
        expect(fields->Dict.keysToArray)->toEqual(["point"])
      | _ => expect("Located arm")->toBe("an ObjectRef")
      }
    | other =>
      expect(other->Option.isSome ? "some other shape" : "nothing")->toBe("a TaggedUnion")
    }
  })

  testSync("an optional union keeps its arms behind Nullable", () => {
    switch shapeOfField(SightingsSpec.stateSchema, "lastSeen") {
    | Some(Nullable(TaggedUnion(name, arms))) =>
      expect((name, arms->Array.length))->toEqual(("Geolocation", 3))
    | _ => expect("lastSeen")->toBe("Nullable(TaggedUnion(...))")
    }
  })

  testSync("an array of unions keeps its arms behind ArrayOf", () => {
    switch shapeOfField(SightingsSpec.stateSchema, "history") {
    | Some(ArrayOf(TaggedUnion(name, _))) => expect(name)->toBe("Geolocation")
    | _ => expect("history")->toBe("ArrayOf(TaggedUnion(...))")
    }
  })

  // The silent degradation this plan set out to end: an unclassifiable union
  // rendered as `String!` with nothing said anywhere.
  testSync("an unnamed union is reported by field and by reason", () => {
    switch SchemaType.unclassifiedUnions(UnnamedSpec.stateSchema->S.castToUnknown) {
    | [{path, reason}] =>
      expect(path)->toBe("verdict")
      expect(reason->String.includes("no name"))->toBe(true)
    | found =>
      expect(found->Array.length)->toBe(1)
    }
  })

  testSync("a classified union and an enum are not reported", () => {
    expect(
      SchemaType.unclassifiedUnions(CustomersSpec.stateSchema->S.castToUnknown)->Array.length,
    )->toBe(0)
  })
})

// ── The SDL ───────────────────────────────────────────────────────────────

describe("GraphQL_FragmentGenerator emits a union", () => {
  let fragment = fragmentFor(
    ~returnTypeName="Ordering_TuCustomer",
    ~specName="TaggedUnionCustomers",
    CustomersSpec.stateSchema,
  )

  testSync("the field is typed as the union", () => {
    expect(
      typeDefFor(fragment, "type Ordering_TuCustomer ")->String.includes(
        "geolocation: Geolocation!",
      ),
    )->toBe(true)
  })

  testSync("the union names one member type per arm", () => {
    expect(typeDefFor(fragment, "union Geolocation"))->toBe(
      "union Geolocation = GeolocationPending | GeolocationLocated | GeolocationUnresolvable",
    )
  })

  testSync("each member type declares the arm's own fields, and no TAG", () => {
    let located = typeDefFor(fragment, "type GeolocationLocated ")
    expect(located->String.includes("point: GeoPoint!"))->toBe(true)
    expect(located->String.includes("TAG"))->toBe(false)
    expect(
      typeDefFor(fragment, "type GeolocationUnresolvable ")->String.includes("reason: String!"),
    )->toBe(true)
  })

  // The merged-API property. AppSync unions same-named types from each source
  // API, and a union of identical definitions is that definition — so a second
  // plugin's copy has to be byte-identical, not merely equivalent. This is the
  // assertion that fails quietly: a name composed from the field path would pass
  // every other test in this file.
  testSync("a second plugin's copy of the union is byte-identical", () => {
    let other = fragmentFor(
      ~returnTypeName="Catalog_TuSighting",
      ~specName="TaggedUnionSightings",
      SightingsSpec.stateSchema,
    )
    let unionOf = f => typeDefFor(f, "union Geolocation")
    expect(unionOf(other))->toBe(unionOf(fragment))
    expect(typeDefFor(other, "type GeolocationLocated "))->toBe(
      typeDefFor(fragment, "type GeolocationLocated "),
    )
  })

  testSync("an optional union is nullable and an array of them is a list", () => {
    let sightings = fragmentFor(
      ~returnTypeName="Catalog_TuSighting",
      ~specName="TaggedUnionSightings",
      SightingsSpec.stateSchema,
    )
    let row = typeDefFor(sightings, "type Catalog_TuSighting ")
    expect(row->String.includes("lastSeen: Geolocation\n"))->toBe(true)
    expect(row->String.includes("history: [Geolocation!]!"))->toBe(true)
  })

  // Unchanged behaviour, pinned: without a name there is no type to emit, and
  // inventing one would publish a contract nothing can stamp a `__typename` for.
  testSync("an unnamed union stays a String", () => {
    let unnamed = fragmentFor(
      ~returnTypeName="Ordering_TuCase",
      ~specName="TaggedUnionUnnamed",
      UnnamedSpec.stateSchema,
    )
    expect(
      typeDefFor(unnamed, "type Ordering_TuCase ")->String.includes("verdict: String!"),
    )->toBe(true)
    expect(typesOf(unnamed)->Array.some(t => t->String.startsWith("union ")))->toBe(false)
  })
})

// ── The JSON Schema ───────────────────────────────────────────────────────

let objAt = (json, key) =>
  json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(key))

describe("SuryToJsonSchema emits the arms as oneOf", () => {
  let json = SuryToJsonSchema.deriveObjectSchema(CustomersSpec.stateSchema->S.castToUnknown)
  let field =
    objAt(json, "properties")
    ->Option.flatMap(p => p->JSON.Decode.object)
    ->Option.flatMap(p => p->Dict.get("geolocation"))
    ->Option.getOr(JSON.Encode.null)

  testSync("the field names the union it is", () => {
    expect(objAt(field, "x-reventless-union")->Option.flatMap(JSON.Decode.string))->toEqual(
      Some("Geolocation"),
    )
  })

  testSync("one member per arm, each discriminated by its TAG const", () => {
    let members =
      objAt(field, "oneOf")->Option.flatMap(JSON.Decode.array)->Option.getOr([])
    expect(members->Array.length)->toBe(3)
    let tags = members->Array.filterMap(m =>
      objAt(m, "properties")
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(p => p->Dict.get("TAG"))
      ->Option.flatMap(t => objAt(t, "const"))
      ->Option.flatMap(JSON.Decode.string)
    )
    expect(tags)->toEqual(["Pending", "Located", "Unresolvable"])
  })

  // Without this a reader has to re-derive `<UnionName><Arm>` in a second repo to
  // map a raw live-channel payload onto an inline fragment.
  testSync("each member publishes the GraphQL type it is emitted as", () => {
    let names =
      objAt(field, "oneOf")
      ->Option.flatMap(JSON.Decode.array)
      ->Option.getOr([])
      ->Array.filterMap(m =>
        objAt(m, "x-reventless-union-member")->Option.flatMap(JSON.Decode.string)
      )
    expect(names)->toEqual([
      "GeolocationPending",
      "GeolocationLocated",
      "GeolocationUnresolvable",
    ])
  })
})
