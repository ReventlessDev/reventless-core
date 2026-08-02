// The claim component's pure decisions — no S3, no DynamoDB stream.
//
// Everything between "a committed event appeared" and "an S3 untag happens" is
// decided by three functions in `Upload_Claim_S3_Ops`: which table a record came
// from, which refs a declared field holds, and whether a ref resolves to an
// object this claimer may touch. The untag itself has no branching left in it,
// so pinning these pins the behaviour that matters.
//
// The direction under test throughout is refusal. An untag this component
// wrongly *skips* costs a delayed cleanup; one it wrongly *performs* removes the
// only thing standing between an object and an expiry rule.

open JestGlobals

module Ops = Upload_Claim_S3_Ops

// `stores` and `refFieldsByTable` are read from the environment at module load,
// so these tests exercise the decision functions against explicitly-built
// inputs rather than a configured module — which is also the honest scope: the
// env parsing is `JSON.parse` plus field reads.

describe("Upload_Claim_S3_Ops.tableNameFromEventSourceArn", () => {
  testSync("reads the table name out of a stream ARN", () =>
    expect(
      Ops.tableNameFromEventSourceArn(
        "arn:aws:dynamodb:eu-west-1:123456789012:table/CatalogDcbEventLog-a1b2c3/stream/2026-08-02T00:00:00.000",
      ),
    )->toEqual(Some("CatalogDcbEventLog-a1b2c3"))
  )

  testSync("returns None for an ARN that is not a table stream", () =>
    expect(Ops.tableNameFromEventSourceArn("arn:aws:sqs:eu-west-1:123456789012:SomeQueue"))->toEqual(
      None,
    )
  )
})

describe("Upload_Claim_S3_Ops.keyOfRef", () => {
  testSync("strips the leading slash the mint side writes", () =>
    expect(Ops.keyOfRef("/Catalog/productImages/sub/uuid/p.png"))->toBe(
      "Catalog/productImages/sub/uuid/p.png",
    )
  )

  testSync("leaves an already-bare key alone", () =>
    expect(Ops.keyOfRef("Catalog/productImages/sub/uuid/p.png"))->toBe(
      "Catalog/productImages/sub/uuid/p.png",
    )
  )
})

describe("Upload_Claim_S3_Ops.refsOfField", () => {
  let single: Ops.refField = {field: "imageUrl", many: false, store: "Catalog.productImages"}
  let multi: Ops.refField = {field: "imageUrls", many: true, store: "Catalog.productImages"}
  let ref1 = "/Catalog/productImages/sub/one/p.png"
  let ref2 = "/Catalog/productImages/sub/two/q.png"

  testSync("reads one ref from a string field", () =>
    expect(
      Ops.refsOfField(~data=Dict.fromArray([("imageUrl", JSON.Encode.string(ref1))]), single),
    )->toEqual([ref1])
  )

  testSync("reads every ref from an array field", () =>
    expect(
      Ops.refsOfField(
        ~data=Dict.fromArray([
          ("imageUrls", JSON.Encode.array([JSON.Encode.string(ref1), JSON.Encode.string(ref2)])),
        ]),
        multi,
      ),
    )->toEqual([ref1, ref2])
  )

  // `StorageRef` admits "" as the "no object" sentinel, so a present-but-empty
  // field must cost no S3 call rather than resolving to the store's root.
  testSync("ignores the empty-string sentinel", () =>
    expect(
      Ops.refsOfField(~data=Dict.fromArray([("imageUrl", JSON.Encode.string(""))]), single),
    )->toEqual([])
  )

  testSync("ignores an absent field", () =>
    expect(Ops.refsOfField(~data=Dict.make(), single))->toEqual([])
  )

  // Arity is declared, not sniffed: a field declared single that arrives as an
  // array (or the reverse) is a schema and a deploy disagreeing, and reading it
  // anyway would mean guessing which one is right.
  testSync("a single-arity field ignores an array value", () =>
    expect(
      Ops.refsOfField(
        ~data=Dict.fromArray([("imageUrl", JSON.Encode.array([JSON.Encode.string(ref1)]))]),
        single,
      ),
    )->toEqual([])
  )

  testSync("a multi-arity field ignores a bare string value", () =>
    expect(
      Ops.refsOfField(~data=Dict.fromArray([("imageUrls", JSON.Encode.string(ref1))]), multi),
    )->toEqual([])
  )

  testSync("ignores non-string elements of an array field", () =>
    expect(
      Ops.refsOfField(
        ~data=Dict.fromArray([
          ("imageUrls", JSON.Encode.array([JSON.Encode.string(ref1), JSON.Encode.int(7)])),
        ]),
        multi,
      ),
    )->toEqual([ref1])
  )
})

describe("Upload_Claim_S3_Ops.claim", () => {
  // The tag key is the contract between three separately-deployed things: the
  // presigned PUT that writes it, this component that removes it, and the
  // lifecycle rule that expires what still carries it. A drift in any one of
  // them is silent — a rule filtered on a key nobody writes matches nothing, and
  // a claimer stripping the wrong key leaves every object tagged.
  testSync("removes the same tag the mint side writes", () =>
    expect(Upload_PendingTag.key)->toBe("reventless:pending")
  )

  // The presigned URL carries `Tagging` as a URL-encoded query string, so the
  // colon has to survive one decode by S3 to land as the key above.
  testSync("the presign tagging parameter decodes to that key and value", () =>
    expect(Upload_PendingTag.putObjectTagging)->toBe("reventless%3Apending=true")
  )
})
