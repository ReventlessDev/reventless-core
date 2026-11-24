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
