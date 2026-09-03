open JestGlobals

// The selection half of the vocabulary. What is asserted is the pair of facts
// the type states — which collection, and no store at all — plus the wrapper
// walk, which is where the analogous reference reader was found to be wrong
// often enough that both now have a test naming the shape it looks through.
describe("MemberRef:", () => {
  testSync("carries the member-reference semantic", () =>
    expect(
      Semantic.get(MemberRef.of_(~field="productImages")->S.castToUnknown)->Option.map(s => s.id),
    )->toEqual(Some(Semantic.Id.memberRef))
  )

  testSync("names the collection, and the view when one is given", () =>
    expect(MemberRef.getTarget(MemberRef.of_(~view="Products", ~field="productImages")))->toEqual(
      Some({Semantic.view: Some("Products"), field: "productImages", plugin: None, content: None}),
    )
  )

  // What a member IS, for a reader holding this field and no sibling's schema.
  testSync("carries the members' own content id when one is given", () =>
    expect(
      MemberRef.getTarget(
        MemberRef.of_(~content=Semantic.Id.imageRef, ~field="productImages"),
      )->Option.flatMap(t => t.content),
    )->toEqual(Some(Semantic.Id.imageRef))
  )

  // The second reading: on a view's own state the collection is on this record,
  // so there is no view to name.
  testSync("leaves the view absent for a declaration on the record itself", () =>
    expect(
      MemberRef.getTarget(MemberRef.of_(~field="productImages"))->Option.map(t => t.view),
    )->toEqual(Some(None))
  )

  testSync("qualifies a view another plugin owns", () =>
    expect(
      MemberRef.getTarget(
        MemberRef.of_(~plugin="catalog", ~view="Products", ~field="productImages"),
      )->Option.flatMap(t => t.plugin),
    )->toEqual(Some("catalog"))
  )

  // The whole difference from the uploadable it selects among, and the reason
  // this type exists: the provisioning walk finds nothing, so no store is
  // created and no upload endpoint is bound on a field that means *choose*.
  testSync("declares no store", () =>
    expect(StorageRef.getFieldStore(MemberRef.of_(~field="productImages")))->toBe(None)
  )

  // `of_` returns an element schema, so on a list of selections the marker sits
  // on the string inside the array and the field's own schema carries nothing.
  // A reader asking the field must ask `getFieldTarget`; `getTarget` answers
  // `None` there, which is not the same as the field declaring nothing.
  describe("through the wrappers around a field's value:", () => {
    let fieldTarget = schema => MemberRef.getFieldTarget(schema->S.castToUnknown)

    testSync("an optional field keeps its declaration", () =>
      expect(
        fieldTarget(S.option(MemberRef.of_(~field="productImages")))->Option.map(t => t.field),
      )->toEqual(Some("productImages"))
    )

    testSync("an array field's element declaration is the field's", () =>
      expect(
        fieldTarget(S.array(MemberRef.of_(~field="productImages")))->Option.map(t => t.field),
      )->toEqual(Some("productImages"))
    )

    testSync("an optional array is followed through both wrappers", () =>
      expect(
        fieldTarget(S.option(S.array(MemberRef.of_(~field="productImages"))))->Option.map(t =>
          t.field
        ),
      )->toEqual(Some("productImages"))
    )

    testSync("a plain string field declares nothing", () =>
      expect(fieldTarget(S.string))->toBe(None)
    )

    // A field of some *other* semantic must not read as a selection — the two
    // travel the same marker and are told apart by their payload alone.
    testSync("a store-declaring field is not a selection", () =>
      expect(fieldTarget(UploadableImage.forField(~store="productImages")))->toBe(None)
    )
  })
})
