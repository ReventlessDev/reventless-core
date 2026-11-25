// A reference code: its semantic, the issued marker a command's field carries, and the tag an
// event's field is found by.

open JestGlobals

@schema
type command =
  | SignUp({memberId: string, code: @s.matches(ReferenceCode.issued) ReferenceCode.t, name: string})
  | Present({sessionId: string, code: ReferenceCode.t})

@schema
type event = MemberSignedUp({memberId: string, code: @s.matches(ReferenceCode.tag) ReferenceCode.t})

let semanticId = (schema: S.t<'a>) => Semantic.get(schema)->Option.map(s => s.id)

describe("a reference code", () => {
  testSync("carries its semantic as the type, as issued and as a tag", () =>
    expect((
      semanticId(ReferenceCode.schema),
      semanticId(ReferenceCode.issued),
      semanticId(ReferenceCode.tag),
    ))->toEqual((
      Some(Semantic.Id.referenceCode),
      Some(Semantic.Id.referenceCode),
      Some(Semantic.Id.referenceCode),
    ))
  )

  testSync("takes any text as it is", () =>
    expect(" AMP-0001"->S.parseOrThrow(~to=ReferenceCode.schema))->toEqual(" AMP-0001")
  )

  testSync("only the field that makes it is issued, and only in its own command", () => {
    let schema = commandSchema->S.castToUnknown
    expect((
      ReferenceCode.variantFieldNames(schema, ~variant="SignUp"),
      ReferenceCode.variantFieldNames(schema, ~variant="Present"),
      ReferenceCode.variantFieldNames(schema, ~variant="Nope"),
    ))->toEqual((["code"], [], []))
  })

  testSync("an optional issued field is found through its wrapper", () => {
    let optional = S.option(ReferenceCode.issued)->S.castToUnknown
    expect(ReferenceCode.isFieldIssued(optional))->toBe(true)
  })

  testSync("an event's tagged field is a tag keyed by the field's name", () =>
    expect(
      DcbTag.extractTags(eventSchema, MemberSignedUp({memberId: "m-1", code: "AMP-0001"})),
    )->toEqual([{DcbTag.key: "code", value: "AMP-0001"}])
  )

  testSync("a made code reads in groups of four", () =>
    expect(ReferenceCode.grouped("7KQ3X9MD4TPA"))->toBe("7KQ3-X9MD-4TPA")
  )
})

// A code presented to a decision finds the thing it names: the event that records it is indexed by
// it, and the decision reads it on a clause of its own, not AND-ed with its own key, which that
// event does not carry. Without this a presented code was never found: the tag was dropped on
// append, since only identities were indexed.
module SignUpSlice = {
  @schema
  type command =
    | SignUp({
        @s.matches(DcbTag.string) memberId: string,
        code: @s.matches(ReferenceCode.issued) ReferenceCode.t,
      })
  @schema
  type event =
    | MemberSignedUp({
        @s.matches(DcbTag.string) memberId: string,
        code: @s.matches(ReferenceCode.tag) ReferenceCode.t,
      })
}

module PresentSlice = {
  @schema
  type command =
    | Present({
        @s.matches(DcbTag.string) sessionId: string,
        code: @s.matches(ReferenceCode.tag) ReferenceCode.t,
      })
  @schema
  type consumedEvent =
    | MemberSignedUp({
        @s.matches(DcbTag.string) memberId: string,
        code: @s.matches(ReferenceCode.tag) ReferenceCode.t,
      })
  @schema
  type event =
    | SessionStarted({
        @s.matches(DcbTag.string) sessionId: string,
        @s.matches(DcbTag.string) memberId: string,
      })
}

describe("a code presented to a decision", () => {
  let scope = DcbTag.deriveEffectiveScope([
    {
      name: "SignUp",
      commandSchema: SignUpSlice.commandSchema->S.castToUnknown,
      consumedEventSchema: S.unit->S.castToUnknown,
      eventSchema: SignUpSlice.eventSchema->S.castToUnknown,
    },
    {
      name: "Present",
      commandSchema: PresentSlice.commandSchema->S.castToUnknown,
      consumedEventSchema: PresentSlice.consumedEventSchema->S.castToUnknown,
      eventSchema: PresentSlice.eventSchema->S.castToUnknown,
    },
  ])

  testSync("indexes the event that records it by it", () =>
    expect(scope.tagKeysByEventType->Dict.get("MemberSignedUp"))->toEqual(
      Some(["code", "memberId"]),
    )
  )

  testSync("is read on a clause of its own", () => {
    let query = DcbTag.buildQueryFromCommand(
      ~eventTypes=["MemberSignedUp", "SessionStarted"],
      ~schema=PresentSlice.commandSchema,
      ~value=PresentSlice.Present({sessionId: "s-1", code: "AMP-0001"}),
      ~tagKeysByEventType=scope.tagKeysByEventType,
      ~crossPartitionTagKeys=scope.crossPartitionTagKeys,
    )
    expect(
      query
      ->Array.filter(
        qi =>
          qi.tags == Some([{DcbTag.key: "code", value: "AMP-0001"}]) &&
            qi.eventTypes->Option.getOr([])->Array.includes("MemberSignedUp"),
      )
      ->Array.length,
    )->toBe(1)
  })
})
