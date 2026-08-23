open JestGlobals

// 🚨 These exist because the bug they cover shipped, and shipped precisely
// because the predicate lived inside a script that runs on import — nothing could
// reach it to assert anything.
//
// The fixtures below are the **real** shapes, captured from live calls rather
// than imagined. That is the whole point: the original guard tested the message
// for the error code, and the message never contains it.

module AwsError = Util_AwsError

@module("./AwsErrorFixtures.mjs")
external throwAwsError: (string, string) => unit = "throwAwsError"

/** The shape an AWS SDK v3 client actually throws, caught the way the real code
    catches it.

    🚨 **Thrown and caught, not constructed.** ReScript's `exn` for a JS error is
    the wrapper its own `catch` builds — a bare `Error` value is a different thing
    and `JsExn.fromException` does not recognise it. A fixture that returned one
    would make every predicate here look broken while the code was fine, which is
    exactly the wrong way round for a regression test. */
let awsError = (~name: string, ~message: string): exn =>
  try {
    throwAwsError(name, message)
    Not_found
  } catch {
  | e => e
  }

describe("Util_AwsError.isNotFound", () => {
  // Captured from `DescribeTable` on a table that does not exist. Note the
  // message: it does NOT contain "ResourceNotFoundException" anywhere, which is
  // exactly why a message-only guard could never match it.
  let dynamoNotFound = awsError(
    ~name="ResourceNotFoundException",
    ~message="Requested resource not found: Table: ReventlessNoSuchTable-probe not found",
  )

  // Captured from `DescribeUserPool` on a pool that does not exist.
  let cognitoNotFound = awsError(
    ~name="ResourceNotFoundException",
    ~message="User pool eu-west-1_zzzNoSuchPl does not exist.",
  )

  testSync("a missing DynamoDB table is recognised from the name alone", () =>
    expect(AwsError.isNotFound(dynamoNotFound))->toBe(true)
  )

  // The regression, stated as the property rather than as the fix: this is what
  // the original guard tested, and it is false for the real error.
  testSync("...and its message does not carry the code, which is why", () =>
    expect(
      AwsError.describe(dynamoNotFound)->String.includes(
        "Requested resource not found",
      ),
    )->toBe(true)
  )

  testSync("a missing Cognito pool is recognised too", () =>
    expect(AwsError.isNotFound(cognitoNotFound))->toBe(true)
  )

  // A wrapped or re-thrown error can lose its `name` while keeping the code in
  // the text, so the fallback earns its place.
  testSync("the code in the message alone still matches", () =>
    expect(
      AwsError.isNotFound(
        awsError(~name="Error", ~message="ResourceNotFoundException: wrapped somewhere"),
      ),
    )->toBe(true)
  )

  // 🚨 The direction that matters for safety. `describeTable` swallows this
  // exception; a guard that said `true` here would report a table as absent when
  // the call was actually refused, and the script would then try to create a
  // table that already exists.
  testSync("a permission failure is not an absence", () =>
    expect(
      AwsError.isNotFound(
        awsError(
          ~name="AccessDeniedException",
          ~message="User is not authorized to perform: dynamodb:DescribeTable",
        ),
      ),
    )->toBe(false)
  )

  testSync("a throttle is not an absence either", () =>
    expect(
      AwsError.isNotFound(
        awsError(~name="ProvisionedThroughputExceededException", ~message="slow down"),
      ),
    )->toBe(false)
  )

  testSync("something that is not a JS error at all is not an absence", () =>
    expect(AwsError.isNotFound(Not_found))->toBe(false)
  )
})

// Without this the top of a CLI reports Node's own
// `UnhandledPromiseRejection ... "#<Object>"`, which names neither the failing
// call nor the reason.
describe("Util_AwsError.describe", () => {
  testSync("names the code and the reason", () =>
    expect(
      AwsError.describe(awsError(~name="AccessDeniedException", ~message="not authorized")),
    )->toBe("AccessDeniedException: not authorized")
  )

  testSync("a non-error value still produces a sentence", () =>
    expect(AwsError.describe(Not_found))->toBe("an unexpected error escaped")
  )

  // Total on purpose: a describer that threw would replace one unreadable
  // failure with another.
  testSync("every shape yields something an operator can read", () =>
    expect(
      [
        awsError(~name="X", ~message="y"),
        Not_found,
      ]->Array.every(e => AwsError.describe(e)->String.length > 0),
    )->toBe(true)
  )
})
