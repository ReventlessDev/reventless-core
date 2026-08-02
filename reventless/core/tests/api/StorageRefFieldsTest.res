// What the claim component ever gets to see, decided here.
//
// `StorageRefFields.fromEventSchema` is the deploy-time reading of the
// `@storageRef` declarations that becomes the claimer's entire input: an event
// variant it does not produce is an event the claimer never reads a record for,
// and a field it does not list is a ref that never gets claimed — so the object
// keeps its pending tag and, on a store with expiry enabled, is eventually
// deleted while something still references it.
//
// Which makes the interesting assertions the negative ones: what is *absent*
// from this output is what silently rots.

open JestGlobals

module Fields = StorageRefFields

// An event union, shaped the way sury encodes a ReScript variant: one object per
// variant, discriminated by a `TAG` string constant.
let variant = (~tag: string, fields: array<(string, S.t<unknown>)>): S.t<unknown> =>
  S.object(s => {
    let _ = s.field("TAG", S.literal(tag)->S.castToUnknown)
    fields->Array.forEach(((name, schema)) => {
      let _ = s.field(name, schema)
    })
    ()
  })->S.castToUnknown

let ref_ = (~plugin: option<string>=?, ~store: string) =>
  Reventless.StorageRef.forStore(~plugin?, ~store)->S.castToUnknown

describe("StorageRefFields.fromEventSchema", () => {
  testSync("finds a declared single-valued ref field and qualifies its store", () => {
    let schema = S.union([variant(~tag="ProductImageChanged", [("imageUrl", ref_(~store="productImages"))])])->S.castToUnknown
    expect(Fields.fromEventSchema(~plugin="Catalog", schema))->toEqual([
      {
        Fields.eventType: "ProductImageChanged",
        fields: [
          {Fields.field: "imageUrl", arity: Single, store: "Catalog.productImages"},
        ],
      },
    ])
  })

  // The annotation's own qualification wins: a field pointing at another
  // plugin's store must not be re-attributed to the plugin that wrote it, or the
  // claimer resolves the wrong bucket and refuses the ref as out-of-store.
  testSync("a qualified declaration keeps the store it names", () => {
    let schema =
      S.union([
        variant(~tag="OrderPhotoAttached", [("photo", ref_(~plugin="Catalog", ~store="productImages"))]),
      ])->S.castToUnknown
    expect(
      Fields.fromEventSchema(~plugin="Ordering", schema)
      ->Array.flatMap(e => e.fields->Array.map(f => f.store)),
    )->toEqual(["Catalog.productImages"])
  })

  // `@storageRef` on an `array<string>` attaches the marker to the ELEMENT, so
  // reading the field schema directly answers None. The claimer needs the arity
  // to know whether to read one value or iterate.
  testSync("finds a multi-valued ref field and records its arity", () => {
    let schema =
      S.union([
        variant(~tag="GalleryReplaced", [("imageUrls", S.array(ref_(~store="productImages"))->S.castToUnknown)]),
      ])->S.castToUnknown
    expect(
      Fields.fromEventSchema(~plugin="Catalog", schema)->Array.flatMap(e => e.fields),
    )->toEqual([{Fields.field: "imageUrls", arity: Multiple, store: "Catalog.productImages"}])
  })

  // Narrow input by construction: a platform whose plugins declare no store
  // provisions no claimer at all, and an event log carrying no declaration is
  // never subscribed to.
  testSync("a variant with no declared field is omitted entirely", () => {
    let schema =
      S.union([
        variant(~tag="ProductRenamed", [("name", S.string->S.castToUnknown)]),
        variant(~tag="ProductImageChanged", [("imageUrl", ref_(~store="productImages"))]),
      ])->S.castToUnknown
    expect(Fields.fromEventSchema(~plugin="Catalog", schema)->Array.map(e => e.eventType))->toEqual([
      "ProductImageChanged",
    ])
  })

  testSync("an event schema with no declaration anywhere yields nothing", () => {
    let schema = S.union([variant(~tag="ProductRenamed", [("name", S.string->S.castToUnknown)])])->S.castToUnknown
    expect(Fields.fromEventSchema(~plugin="Catalog", schema))->toEqual([])
  })

  // A string field that merely looks like a ref is not one. Declaration
  // outranks inference everywhere else in the framework, and this is the reading
  // that has to agree with `Plugin_Structure`'s — the claimer can only reach a
  // store the deploy actually provisioned.
  testSync("an unannotated string field is not treated as a ref", () => {
    let schema =
      S.union([variant(~tag="ProductImported", [("imageUrl", S.string->S.castToUnknown)])])->S.castToUnknown
    expect(Fields.fromEventSchema(~plugin="Catalog", schema))->toEqual([])
  })

  testSync("a single-variant (non-union) event schema is read the same way", () => {
    let schema = variant(~tag="ProductImageChanged", [("imageUrl", ref_(~store="productImages"))])
    expect(Fields.fromEventSchema(~plugin="Catalog", schema)->Array.map(e => e.eventType))->toEqual([
      "ProductImageChanged",
    ])
  })
})

describe("StorageRefFields.toJson", () => {
  // The wire form crosses into a Lambda's environment, where the handler decodes
  // it with plain JSON reads. Both ends are pinned here because a drift is
  // silent: an unreadable entry is indistinguishable from an absent one, and an
  // absent one means "nothing to claim".
  testSync("emits field, arity and store per event type", () => {
    let entries: array<Fields.eventRefFields> = [
      {
        eventType: "ProductImageChanged",
        fields: [{field: "imageUrl", arity: Single, store: "Catalog.productImages"}],
      },
      {
        eventType: "GalleryReplaced",
        fields: [{field: "imageUrls", arity: Multiple, store: "Catalog.productImages"}],
      },
    ]
    expect(Fields.toJson(entries)->JSON.stringify)->toBe(
      `{"ProductImageChanged":[{"field":"imageUrl","arity":"one","store":"Catalog.productImages"}],` ++
      `"GalleryReplaced":[{"field":"imageUrls","arity":"many","store":"Catalog.productImages"}]}`,
    )
  })
})

describe("StorageRefFields.storesOf", () => {
  testSync("collects the distinct stores an event log's declarations reach", () => {
    let entries: array<Fields.eventRefFields> = [
      {
        eventType: "A",
        fields: [{field: "a", arity: Single, store: "Catalog.productImages"}],
      },
      {
        eventType: "B",
        fields: [
          {field: "b", arity: Single, store: "Catalog.productImages"},
          {field: "c", arity: Multiple, store: "Ordering.receipts"},
        ],
      },
    ]
    expect(Fields.storesOf(entries))->toEqual(["Catalog.productImages", "Ordering.receipts"])
  })
})
