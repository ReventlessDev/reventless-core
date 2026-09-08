open JestGlobals

@schema
type lifecycle =
  | Placed
  | Shipped
  | Cancelled

@schema
type order = {
  orderId: string,
  lifecycle: lifecycle,
  trail: Lifecycle.Trail.t<lifecycle>,
}

@schema
type freeText = {lifecycle: string}

@schema
type unnamed = {phase: lifecycle}

let unknownOrder = orderSchema->S.castToUnknown

let dict = (json: string) =>
  json->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow(~message="expected an object")

let parses = (raw: string) =>
  switch raw->Util_Sury.fromJsonString(orderSchema) {
  | _ => true
  | exception _ => false
  }

// The load-bearing case is the declaration itself: `Trail.t<lifecycle>` has to
// resolve to a schema through sury-ppx alone, or a view cannot declare a trail
// in one line. The rest holds the two lookups the projection machinery makes.
describe("Lifecycle:", () => {
  describe("a declared trail field:", () => {
    testSync("resolves to a schema from the type alone", () =>
      expect(
        {
          orderId: "o1",
          lifecycle: Placed,
          trail: [{state: Placed, at: "2026-03-02T09:00:00Z"}],
        }->Util_Sury.toJsonString(orderSchema),
      )->toBe(
        `{"orderId":"o1","lifecycle":"Placed","trail":[{"state":"Placed","at":"2026-03-02T09:00:00Z"}]}`,
      )
    )

    testSync("is found by name on the state schema", () =>
      expect(Lifecycle.Trail.fieldName(unknownOrder))->toEqual(Some("trail"))
    )

    // The entry's instant is a `DateTime`, so the sentinel a per-state field
    // used to hold is refused on the write path as well as the read path.
    testSync("refuses an entry whose instant is not one", () =>
      expect(
        parses(`{"orderId":"o1","lifecycle":"Placed","trail":[{"state":"Placed","at":""}]}`),
      )->toBe(false)
    )
  })

  describe("the lifecycle field:", () => {
    testSync("is the enum field named lifecycle", () =>
      expect(Lifecycle.fieldName(unknownOrder))->toEqual(Some("lifecycle"))
    )

    // A command menu filtered against `allowedStates` needs states to compare
    // with, so free text is not a lifecycle.
    testSync("is not a string field of the same name", () =>
      expect(Lifecycle.fieldName(freeTextSchema->S.castToUnknown))->toEqual(None)
    )

    testSync("is not guessed from another name", () =>
      expect(Lifecycle.fieldName(unnamedSchema->S.castToUnknown))->toEqual(None)
    )
  })

  describe("recording an entry:", () => {
    testSync("appends to an empty trail", () => {
      let state = dict(`{"lifecycle":"Placed","trail":[]}`)
      state->Lifecycle.Trail.record(
        ~field="trail",
        ~state=JSON.Encode.string("Placed"),
        ~at="2026-03-02T09:00:00Z",
      )
      expect(state->JSON.Encode.object->JSON.stringify)->toBe(
        `{"lifecycle":"Placed","trail":[{"state":"Placed","at":"2026-03-02T09:00:00Z"}]}`,
      )
    })

    // The same state twice is the case a map cannot hold: a reopened order is
    // `Placed` again, at a different instant, and both visits are facts.
    testSync("keeps a repeated state as a second entry", () => {
      let state = dict(
        `{"trail":[{"state":"Placed","at":"2026-03-02T09:00:00Z"},{"state":"Cancelled","at":"2026-03-02T10:00:00Z"}]}`,
      )
      state->Lifecycle.Trail.record(
        ~field="trail",
        ~state=JSON.Encode.string("Placed"),
        ~at="2026-03-02T11:00:00Z",
      )
      expect(state->JSON.Encode.object->JSON.stringify)->toBe(
        `{"trail":[{"state":"Placed","at":"2026-03-02T09:00:00Z"},{"state":"Cancelled","at":"2026-03-02T10:00:00Z"},{"state":"Placed","at":"2026-03-02T11:00:00Z"}]}`,
      )
    })
  })
})
