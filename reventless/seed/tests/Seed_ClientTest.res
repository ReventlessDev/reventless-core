open JestGlobals

// A seed issues hundreds of commands against runtimes a preceding reset left
// cold, so the endpoint faulting on one of them is a normal event rather than an
// exceptional one. Before the retry, a single `InternalFailure` in that batch
// aborted the run and left a half-seeded store that could only be recovered by a
// full wipe and a re-run — for a request that would have succeeded on being
// asked again.
//
// What makes the retry safe is the classifier, so that is what these pin. A
// fault on the endpoint's side carries no information about the document and is
// worth resending; anything that is an *answer* — a validation error, an unknown
// field, a refused token — comes back identical however many times it is asked,
// and resending it only delays the failure the operator needs to see.

let errors = entries => JSON.Encode.array(entries->Array.map(JSON.Encode.object))

let errorOfType = errorType =>
  Dict.fromArray([("errorType", JSON.Encode.string(errorType))])

describe("Seed_Client.isTransient:", () => {
  testSync("resends a fault on the endpoint's own side", () =>
    ["InternalFailure", "ServiceUnavailable", "Throttling", "TooManyRequestsException"]
    ->Array.forEach(t =>
      expect(Seed_Client.isTransient(errors([errorOfType(t)])))->toBe(true)
    )
  )

  // The exact payload the seed aborted on.
  testSync("resends the shape AppSync actually returned", () => {
    let payload = JSON.parseOrThrow(`[{"errorType":"InternalFailure","message":"An internal failure occurred."}]`)
    expect(Seed_Client.isTransient(payload))->toBe(true)
  })

  testSync("fails fast on an error that is an answer", () =>
    ["ValidationException", "Unauthorized", "FieldUndefined"]->Array.forEach(t =>
      expect(Seed_Client.isTransient(errors([errorOfType(t)])))->toBe(false)
    )
  )

  // A real error sitting alongside a transient one still means the request was
  // wrong, and resending it cannot make it right.
  testSync("refuses to resend a batch that mixes a real error in", () =>
    expect(
      Seed_Client.isTransient(
        errors([errorOfType("InternalFailure"), errorOfType("ValidationException")]),
      ),
    )->toBe(false)
  )

  // `Array.every` is vacuously true on an empty array, which would turn "the
  // endpoint said errors but named none" into an endless resend.
  testSync("treats an empty or untyped error list as final", () => {
    expect(Seed_Client.isTransient(errors([])))->toBe(false)
    expect(Seed_Client.isTransient(errors([Dict.fromArray([("message", JSON.Encode.string("boom"))])])))
    ->toBe(false)
    expect(Seed_Client.isTransient(JSON.Encode.null))->toBe(false)
  })
})
