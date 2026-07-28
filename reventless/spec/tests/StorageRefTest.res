open JestGlobals

// The point of this type is that an append-only log cannot be un-written. These
// cases are the values that used to reach it through a bare `string` field.
describe("StorageRef:", () => {
  describe("grammar:", () => {
    let accepts = raw =>
      switch StorageRef.fromString(raw) {
      | Ok(_) => true
      | Error(_) => false
      }

    testSync("accepts a minted ref", () =>
      expect(accepts("/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/photo.jpg"))->toBe(true)
    )

    testSync("accepts a ref with an identity segment", () =>
      expect(accepts("/uploads/user-42/3e7b41c8/photo.jpg"))->toBe(true)
    )

    testSync("rejects an external https URL", () =>
      expect(accepts("https://evil.example/photo.jpg"))->toBe(false)
    )

    testSync("rejects a data URI", () =>
      expect(accepts("data:image/png;base64,iVBORw0KGgo="))->toBe(false)
    )

    testSync("rejects a protocol-relative URL", () =>
      expect(accepts("//evil.example/photo.jpg"))->toBe(false)
    )

    testSync("rejects a relative path", () => expect(accepts("uploads/photo.jpg"))->toBe(false))

    testSync("rejects a bare prefix with no object path", () =>
      expect(accepts("/uploads"))->toBe(false)
    )

    testSync("rejects traversal segments", () =>
      expect(accepts("/uploads/../../etc/passwd"))->toBe(false)
    )

    testSync("rejects empty segments", () => expect(accepts("/uploads//photo.jpg"))->toBe(false))

    testSync("rejects the empty string", () => expect(accepts(""))->toBe(false))

    testSync("says why it failed", () =>
      expect(
        switch StorageRef.fromString("https://evil.example/x.jpg") {
        | Error(why) => why->String.includes("storage ref")
        | Ok(_) => false
        },
      )->toBe(true)
    )
  })

  describe("field schema:", () => {
    let schema = StorageRef.forStore(~store="productImages")

    let parses = (raw: string) =>
      switch raw->S.parseOrThrow(schema) {
      | _ => true
      | exception _ => false
      }

    testSync("accepts a minted ref", () =>
      expect(parses("/uploads/3e7b41c8/photo.jpg"))->toBe(true)
    )

    testSync("rejects an external URL", () =>
      expect(parses("https://evil.example/photo.jpg"))->toBe(false)
    )

    // The fields this marks are non-optional, and a producer with no object to
    // reference already writes "" to mean absence. See the note on `forStore`.
    testSync("admits the empty no-object sentinel", () => expect(parses(""))->toBe(true))

    testSync("carries the store identity", () =>
      expect(
        StorageRef.getStore(schema->S.castToUnknown)->Option.map(t => t.store),
      )->toEqual(Some("productImages"))
    )

    testSync("carries a qualified store's plugin", () =>
      expect(
        StorageRef.forStore(~plugin="catalog", ~store="productImages")
        ->S.castToUnknown
        ->StorageRef.getStore
        ->Option.flatMap(t => t.plugin),
      )->toEqual(Some("catalog"))
    )

    // A storage ref is not an entity reference and must not route as one.
    testSync("is not DCB-tagged", () =>
      expect(DcbTag.isTagged(schema->S.castToUnknown))->toBe(false)
    )

    testSync("is not a reference", () =>
      expect(Reference.getTarget(schema->S.castToUnknown))->toBe(None)
    )
  })
})
