open JestGlobals

// Build a plain JS object shaped like a JS Error / SDK exception, cast to
// JsExn.t so the classifiers can be called without a real throw/catch.
type testError = {name: string, message: string}
let mkErr = (~name, ~message): JsExn.t => Obj.magic(({name, message}: testError))

module Assoc = AppSync_SourceApiAssociation_Retrying

describe("AppSync_SourceApiAssociation_Retrying.isConcurrentModificationError", () => {
  testSync("true for ConcurrentModificationException by name", () => {
    let err = mkErr(~name="ConcurrentModificationException", ~message="Schema is currently being merged")
    expect(Assoc.isConcurrentModificationError(err))->toBe(true)
  })

  testSync("true when the name rides in the message", () => {
    let err = mkErr(~name="Error", ~message="ConcurrentModificationException: try again")
    expect(Assoc.isConcurrentModificationError(err))->toBe(true)
  })

  testSync("false for an unrelated error", () => {
    let err = mkErr(~name="ValidationException", ~message="bad SDL")
    expect(Assoc.isConcurrentModificationError(err))->toBe(false)
  })
})

describe("AppSync_SourceApiAssociation_Retrying.isRetryableAssociationError", () => {
  describe("returns true", () => {
    [
      "ConcurrentModificationException",
      "ThrottlingException",
      "TooManyRequestsException",
      "InternalFailureException",
      "ServiceUnavailableException",
    ]->Array.forEach(name =>
      testSync(name, () => {
        expect(Assoc.isRetryableAssociationError(mkErr(~name, ~message="x")))->toBe(true)
      })
    )
  })

  describe("returns false", () => {
    testSync("permanent ValidationException", () => {
      expect(
        Assoc.isRetryableAssociationError(mkErr(~name="ValidationException", ~message="bad input")),
      )->toBe(false)
    })

    testSync("NotFoundException (a delete no-op, not a retry)", () => {
      expect(
        Assoc.isRetryableAssociationError(
          mkErr(~name="NotFoundException", ~message="association not found"),
        ),
      )->toBe(false)
    })

    testSync("non-exception value", () => {
      let notErr: JsExn.t = Obj.magic(42)
      expect(Assoc.isRetryableAssociationError(notErr))->toBe(false)
    })
  })
})

describe("AppSync_SourceApiAssociation_Retrying.isAlreadyGoneError", () => {
  testSync("true for NotFoundException", () => {
    expect(Assoc.isAlreadyGoneError(mkErr(~name="NotFoundException", ~message="gone")))->toBe(true)
  })

  testSync("true when message says not found", () => {
    expect(Assoc.isAlreadyGoneError(mkErr(~name="Error", ~message="merged API not found")))->toBe(
      true,
    )
  })

  testSync("false for a transient race (must not be swallowed as gone)", () => {
    expect(
      Assoc.isAlreadyGoneError(mkErr(~name="ConcurrentModificationException", ~message="retry")),
    )->toBe(false)
  })
})

describe("AppSync_SourceApiAssociation_Retrying.idsFromArn", () => {
  testSync("parses mergedApiId + associationId from an association ARN", () => {
    let arn = "arn:aws:appsync:eu-west-1:123456789012:apis/mgd123/sourceApiAssociations/assoc456"
    switch Assoc.idsFromArn(arn) {
    | Some(ids) =>
      expect(ids.mergedApiIdentifier)->toBe("mgd123")
      expect(ids.associationId)->toBe("assoc456")
    | None => fail("expected Some")
    }
  })

  testSync("None for an ARN that is not an association", () => {
    let arn = "arn:aws:appsync:eu-west-1:123456789012:apis/mgd123"
    expect(Assoc.idsFromArn(arn)->Option.isNone)->toBe(true)
  })
})

describe("AppSync_SourceApiAssociation_Retrying.idsFromComposite", () => {
  testSync("parses the classic '<mergedApiId>,<assocId>' id", () => {
    switch Assoc.idsFromComposite("mgd123,assoc456") {
    | Some(ids) =>
      expect(ids.mergedApiIdentifier)->toBe("mgd123")
      expect(ids.associationId)->toBe("assoc456")
    | None => fail("expected Some")
    }
  })

  testSync("None for a non-composite string", () => {
    expect(Assoc.idsFromComposite("just-one-value")->Option.isNone)->toBe(true)
  })
})

// pulumi.dynamic.Resource defines a resource property per KEY of the props
// object, so the output-only fields must be present (with an undefined value)
// or `association.associationId` is a bare `undefined` and the merge gate
// calls GetSourceApiAssociation without an id.
describe("AppSync_SourceApiAssociation_Retrying.resourcePropsOf", () => {
  let keysOf: Assoc.resourceProps => array<string> = p => Object.keysToArray(Obj.magic(p))
  let props = Assoc.resourcePropsOf({
    mergedApiIdentifier: Obj.magic("merged-arn"),
    sourceApiIdentifier: Obj.magic("src123"),
    mergeType: Obj.magic("AUTO_MERGE"),
  })

  testSync("declares arn + associationId as output-only keys", () => {
    expect(props->keysOf->Array.includes("arn"))->toBe(true)
    expect(props->keysOf->Array.includes("associationId"))->toBe(true)
    expect(props.arn->Nullable.toOption->Option.isNone)->toBe(true)
    expect(props.associationId->Nullable.toOption->Option.isNone)->toBe(true)
  })

  testSync("passes the three real inputs through", () => {
    expect((props.mergedApiIdentifier->Obj.magic: string))->toBe("merged-arn")
    expect((props.sourceApiIdentifier->Obj.magic: string))->toBe("src123")
    expect((props.mergeType->Obj.magic: string))->toBe("AUTO_MERGE")
  })
})
