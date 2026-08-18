open JestGlobals

// The uploadable family and its unowned counterparts. What is asserted here is
// the pair of facts each type states, and — for the uploadable pair — that the
// store declaration is the one the provisioning walk already reads.
describe("Uploadable:", () => {
  let semanticOf = schema => Semantic.get(schema->S.castToUnknown)->Option.map(s => s.id)

  describe("UploadableImage:", () => {
    let schema = UploadableImage.forField(~store="productImages")

    testSync("carries the image semantic", () =>
      expect(semanticOf(schema))->toEqual(Some(Semantic.Id.uploadableImage))
    )

    // Fact 1 of the design: the store rides on the payload, not on the id, so
    // the walk that provisions `@storageRef` stores provisions these unchanged.
    testSync("declares its store through the shared StoredIn payload", () =>
      expect(StorageRef.getStore(schema->S.castToUnknown)->Option.map(t => t.store))->toEqual(
        Some("productImages"),
      )
    )

    testSync("carries a qualified store's plugin", () =>
      expect(
        UploadableImage.forField(~plugin="catalog", ~store="productImages")
        ->S.castToUnknown
        ->StorageRef.getStore
        ->Option.flatMap(t => t.plugin),
      )->toEqual(Some("catalog"))
    )

    // The grammar is StorageRef's, re-labelled rather than restated — so a
    // retyped field validates exactly what it validated before.
    testSync("validates as a storage ref does", () =>
      expect(
        [
          "/uploads/3e7b41c8/photo.jpg",
          "",
          "https://example.com/photo.jpg",
          "data:image/png;base64,AAAA",
        ]->Array.map(raw =>
          switch UploadableImage.fromString(raw) {
          | Ok(_) => true
          | Error(_) => false
          }
        ),
      )->toEqual([true, false, false, false])
    )

    testSync("is not a reference", () =>
      expect(Reference.getTarget(schema->S.castToUnknown))->toBe(None)
    )
  })

  describe("UploadableFile:", () => {
    let schema = UploadableFile.forField(~store="datasheets")

    testSync("carries the file semantic", () =>
      expect(semanticOf(schema))->toEqual(Some(Semantic.Id.uploadableFile))
    )

    testSync("declares its store the same way", () =>
      expect(StorageRef.getStore(schema->S.castToUnknown)->Option.map(t => t.store))->toEqual(
        Some("datasheets"),
      )
    )
  })

  // The unowned counterparts state the content fact and nothing about storage.
  describe("ImageRef / FileRef:", () => {
    testSync("carry their own semantics", () =>
      expect((semanticOf(ImageRef.schema), semanticOf(FileRef.schema)))->toEqual((
        Some(Semantic.Id.imageRef),
        Some(Semantic.Id.fileRef),
      ))
    )

    // The whole difference from the uploadable pair: nothing is provisioned, so
    // the store walk must find nothing here.
    testSync("declare no store", () =>
      expect((
        StorageRef.getStore(ImageRef.schema->S.castToUnknown),
        StorageRef.getStore(FileRef.schema->S.castToUnknown),
      ))->toEqual((None, None))
    )

    testSync("accept a web address and an origin-relative path", () =>
      expect(
        [
          "https://supplier.example/img/1.jpg",
          "http://supplier.example/img/1.jpg",
          "/uploads/3e7b41c8/photo.jpg",
        ]->Array.map(raw =>
          switch ImageRef.fromString(raw) {
          | Ok(_) => true
          | Error(_) => false
          }
        ),
      )->toEqual([true, true, true])
    )

    // The rule worth stating: an append-only log makes an inlined payload
    // permanent, so a data: URI is refused here as it is for a stored ref.
    testSync("refuse a data: URI, a protocol-relative host and the empty string", () =>
      expect(
        ["data:image/png;base64,AAAA", "//evil.example/x.png", "", "photo.jpg"]->Array.map(raw =>
          switch FileRef.fromString(raw) {
          | Ok(_) => true
          | Error(_) => false
          }
        ),
      )->toEqual([false, false, false, false])
    )
  })
})
