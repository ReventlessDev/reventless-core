open JestGlobals

// The composite half of the uploadable vocabulary: an image and the text that
// goes with it, in one value. What is asserted is the pair of facts the type
// states — which store, and that a *field* reader finds it through the wrappers
// a host puts around the value. The second is the one worth a test: the marker
// sits on the record rather than on the reference inside it precisely because
// `getFieldStore` looks through an optional wrapper and an array element and no
// further, and a marker one level deeper would go unprovisioned in silence.
describe("CaptionedImage:", () => {
  let field = CaptionedImage.forField(~store="productImages")

  testSync("carries the captioned-image semantic", () =>
    expect(Semantic.get(field)->Option.map(s => s.id))->toEqual(
      Some(Semantic.Id.captionedImage),
    )
  )

  testSync("declares the store it was built for", () =>
    expect(StorageRef.getStore(field))->toEqual(
      Some({Semantic.plugin: None, store: "productImages", threshold: None}),
    )
  )

  testSync("qualifies a store another plugin owns", () =>
    expect(
      StorageRef.getStore(
        CaptionedImage.forField(~plugin="catalog", ~store="productImages"),
      )->Option.flatMap(t => t.plugin),
    )->toEqual(Some("catalog"))
  )

  describe("as a field's declaration:", () => {
    let store = schema =>
      StorageRef.getFieldStore(schema)->Option.map(((target, arity)) => (target.store, arity))

    testSync("a bounded host's scalar declares one", () =>
      expect(store(S.option(field)))->toEqual(Some(("productImages", StorageRef.Single)))
    )

    testSync("a set declares many", () =>
      expect(store(S.array(field)))->toEqual(Some(("productImages", StorageRef.Multiple)))
    )
  })

  // The rule a renderer applies, written once here so no consumer restates it.
  describe("the text that replaces the image:", () => {
    let ref = UploadableImage.unsafe("/uploads/00000000-0000-4000-8000-000000000001/a")

    testSync("is the alt text when there is one", () =>
      expect(CaptionedImage.altTextOf({ref, altText: "Blue shoe", caption: "Front view"}))->toEqual(
        Some("Blue shoe"),
      )
    )

    // Deliberately impure: the pure rule would emit `alt=""` on a photo a host
    // captioned, which declares it decorative.
    testSync("falls back to the caption rather than to nothing", () =>
      expect(CaptionedImage.altTextOf({ref, caption: "Front view"}))->toEqual(Some("Front view"))
    )

    testSync("is absent when the member carries neither", () =>
      expect(CaptionedImage.altTextOf({ref: ref}))->toEqual(None)
    )
  })
})
