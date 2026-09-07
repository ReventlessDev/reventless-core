open JestGlobals

// A field marker and a branded semantic type on the same field. Both markers
// used to test for the literal `string` keyword, so both saw the brand instead
// of the string and refused a field they should have taken — which would have
// made declaring what a field *is* cost it whatever the marker gave.
//
// The composition assertion is the one that matters. `@owner` cannot see the
// schema sury-ppx derives from `Email.t`, so the tempting fix is to inject
// `Owner.string` over it: that type-checks, passes an "is it marked" test, and
// silently leaves the field a plain string with the address grammar gone.
// Asserting the marker is there proves nothing on its own — the rejection below
// is what says the brand survived.
describe("a field marker on a branded semantic:", () => {
  let stateSchema = PsBrandedMarkersReadModel.stateSchema->S.castToUnknown

  let fieldOf = name =>
    switch stateSchema {
    | Object({properties}) => properties->Dict.get(name)
    | _ => None
    }

  describe("@owner on an Email field:", () => {
    testSync("marks the field as the owner", () =>
      expect(fieldOf("email")->Option.mapOr(false, Reventless.Owner.isFieldOwner))->toBe(true)
    )

    testSync("keeps the email semantic", () =>
      expect(
        fieldOf("email")
        ->Option.flatMap(Reventless.Semantic.getFrom)
        ->Option.map(s => s.id),
      )->toEqual(Some("email"))
    )

    // The regression a substituting fix would land, and it lands in silence:
    // the row still scopes to its owner, and the field accepts anything.
    testSync("still rejects what is not an address", () => {
      let parses = raw =>
        switch fieldOf("email") {
        | Some(schema) =>
          switch raw->JSON.Encode.string->S.parseOrThrow(~to=schema) {
          | _ => true
          | exception _ => false
          }
        | None => false
        }
      expect((parses("buyer@example.com"), parses("buyer")))->toEqual((true, false))
    })
  })

  describe("@displayName on a DateTime field:", () => {
    testSync("names the row by it", () =>
      expect(
        S.Metadata.get(stateSchema, ~id=Reventless.DisplayName.displayNameId)->Option.map(d =>
          d.fields
        ),
      )->toEqual(Some(["openedAt"]))
    )

    testSync("and the instant grammar survives", () => {
      let parses = raw =>
        switch fieldOf("openedAt") {
        | Some(schema) =>
          switch raw->JSON.Encode.string->S.parseOrThrow(~to=schema) {
          | _ => true
          | exception _ => false
          }
        | None => false
        }
      expect((parses("2026-03-02T09:00:00Z"), parses("tomorrow")))->toEqual((true, false))
    })
  })
})
