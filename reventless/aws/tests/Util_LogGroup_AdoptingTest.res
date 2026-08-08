open JestGlobals

// Build a plain JS object shaped like a JS Error / SDK exception, cast to
// JsExn.t so the classifiers can be called without a real throw/catch.
type testError = {name: string, message: string}
let mkErr = (~name, ~message): JsExn.t => Obj.magic(({name, message}: testError))

module Adopting = Util_LogGroup_Adopting

let tags = Dict.fromArray([("Name", "PlatformApiAppSyncLogGroup"), ("reventless:role", "Logs")])

let normalisedOuts: Adopting.outs = {
  logGroupName: Nullable.make("/aws/appsync/apis/abc123"),
  arn: Nullable.make("arn:aws:logs:eu-west-1:1:log-group:/aws/appsync/apis/abc123:*"),
  retentionInDays: Nullable.make(7),
  tags: Nullable.make(tags),
  managedBy: Nullable.make(Adopting.marker),
}

let inputs: Adopting.providerInputs = {
  logGroupName: "/aws/appsync/apis/abc123",
  retentionInDays: 7,
  tags,
}

describe("Util_LogGroup_Adopting.isAlreadyExistsError", () => {
  testSync("true for the error this provider exists to absorb", () =>
    expect(
      Adopting.isAlreadyExistsError(
        mkErr(~name="ResourceAlreadyExistsException", ~message="The specified log group already exists"),
      ),
    )->toBe(true)
  )

  testSync("true when the code rides in the message", () =>
    expect(
      Adopting.isAlreadyExistsError(
        mkErr(~name="InvalidParameterException", ~message="ResourceAlreadyExistsException: exists"),
      ),
    )->toBe(true)
  )

  testSync("false for a permission failure, which must still fail loudly", () =>
    expect(
      Adopting.isAlreadyExistsError(mkErr(~name="AccessDeniedException", ~message="not authorized")),
    )->toBe(false)
  )
})

describe("Util_LogGroup_Adopting.isRetryableError", () => {
  testSync("true for the concurrent-write rejection on one group", () =>
    expect(Adopting.isRetryableError(mkErr(~name="OperationAbortedException", ~message="x")))->toBe(
      true,
    )
  )

  testSync("false for an already-exists error — that is absorbed, not retried", () =>
    expect(
      Adopting.isRetryableError(mkErr(~name="ResourceAlreadyExistsException", ~message="x")),
    )->toBe(false)
  )
})

describe("Util_LogGroup_Adopting.taggableArn", () => {
  testSync("strips the trailing `:*` TagResource rejects", () =>
    expect(
      Adopting.taggableArn("arn:aws:logs:eu-west-1:1:log-group:/aws/appsync/apis/abc123:*"),
    )->toBe("arn:aws:logs:eu-west-1:1:log-group:/aws/appsync/apis/abc123")
  )

  testSync("leaves an already-taggable arn alone", () => {
    let arn = "arn:aws:logs:eu-west-1:1:log-group:/aws/appsync/apis/abc123"
    expect(Adopting.taggableArn(arn))->toBe(arn)
  })
})

describe("Util_LogGroup_Adopting.sameTags", () => {
  testSync("is insensitive to key order", () =>
    expect(
      Adopting.sameTags(
        Dict.fromArray([("a", "1"), ("b", "2")]),
        Dict.fromArray([("b", "2"), ("a", "1")]),
      ),
    )->toBe(true)
  )

  testSync("sees a changed value", () =>
    expect(
      Adopting.sameTags(Dict.fromArray([("a", "1")]), Dict.fromArray([("a", "2")])),
    )->toBe(false)
  )

  testSync("sees an added key", () =>
    expect(
      Adopting.sameTags(Dict.fromArray([("a", "1")]), Dict.fromArray([("a", "1"), ("b", "2")])),
    )->toBe(false)
  )
})

describe("Util_LogGroup_Adopting.diff_", () => {
  testSync("no change when the live state already matches", () => {
    let result = Adopting.diff_("id", normalisedOuts, inputs)
    expect(result.changes)->toBe(false)
    expect(result.replaces)->toEqual([])
  })

  testSync("a retention change is an update, not a replace", () => {
    let result = Adopting.diff_("id", normalisedOuts, {...inputs, retentionInDays: 30})
    expect(result.changes)->toBe(true)
    expect(result.replaces)->toEqual([])
  })

  testSync("a tag change is an update, not a replace", () => {
    let result = Adopting.diff_(
      "id",
      normalisedOuts,
      {...inputs, tags: Dict.fromArray([("Name", "renamed")])},
    )
    expect(result.changes)->toBe(true)
    expect(result.replaces)->toEqual([])
  })

  testSync("a name change replaces — CloudWatch cannot rename a group in place", () => {
    let result = Adopting.diff_(
      "id",
      normalisedOuts,
      {...inputs, logGroupName: "/aws/appsync/apis/def456"},
    )
    expect(result.changes)->toBe(true)
    expect(result.replaces)->toEqual(["logGroupName"])
  })

  testSync("replacing creates before deleting, so the old group stays readable", () => {
    let result = Adopting.diff_(
      "id",
      normalisedOuts,
      {...inputs, logGroupName: "/aws/appsync/apis/def456"},
    )
    expect(result.deleteBeforeReplace)->toBe(false)
  })

  // State written by the classic `aws:cloudwatch/logGroup:LogGroup` resource the
  // alias adopts carries none of this provider's fields. It has to report a
  // change even when nothing differs, because the following update is what
  // writes this provider's output shape — and Pulumi's `__provider` — into state.
  testSync("adopted classic state is always a change, so the update normalises it", () => {
    let classicOuts: Adopting.outs = {
      logGroupName: Nullable.undefined,
      arn: Nullable.undefined,
      retentionInDays: Nullable.undefined,
      tags: Nullable.undefined,
      managedBy: Nullable.undefined,
    }
    let result = Adopting.diff_("id", classicOuts, inputs)
    expect(result.changes)->toBe(true)
  })

  testSync("adopted classic state never replaces on a field it does not carry", () => {
    let classicOuts: Adopting.outs = {
      logGroupName: Nullable.undefined,
      arn: Nullable.undefined,
      retentionInDays: Nullable.undefined,
      tags: Nullable.undefined,
      managedBy: Nullable.undefined,
    }
    let result = Adopting.diff_("id", classicOuts, inputs)
    expect(result.replaces)->toEqual([])
  })
})
