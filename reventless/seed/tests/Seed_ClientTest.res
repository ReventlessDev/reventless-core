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

// An account's listed groups are not what authorizes it — the token's are. Both
// platforms narrow a token to the single role the caller last chose, so a seed
// can log in as an account the user list shows as `[Admin, Shopper]` and present
// a token carrying `Shopper` alone. The refusal that follows names the field and
// not the caller, and the account list cannot explain it either. These pin the
// reading-back that turns that into a sentence.

let b64url = payload =>
  payload
  ->NodeBuffer.fromStringUtf8
  ->NodeBuffer.toStringBase64Url

let jwt = claims =>
  `header.${b64url(JSON.stringify(JSON.Encode.object(Dict.fromArray(claims))))}.signature`

let localToken = claims =>
  `${b64url(JSON.stringify(JSON.Encode.object(Dict.fromArray(claims))))}.signature`

let strings = values => JSON.Encode.array(values->Array.map(JSON.Encode.string))

let clientWith = token => {
  let c = Seed_Client.make(~config={endpoint: "http://example.invalid/graphql"})
  c->Seed_Client.useToken(token)
  c
}

describe("Seed_Client.effectiveGroups:", () => {
  // A Cognito id token carries its payload in the second segment, a local dev
  // token in the first. Neither platform should have to announce which it is.
  testSync("reads the payload wherever the provider put it", () => {
    expect(
      clientWith(jwt([("cognito:groups", strings(["Admin", "Shopper"]))]))->Seed_Client.effectiveGroups,
    )->toEqual(Some(["Admin", "Shopper"]))
    expect(
      clientWith(localToken([("groups", strings(["Merchandiser"]))]))->Seed_Client.effectiveGroups,
    )->toEqual(Some(["Merchandiser"]))
  })

  // An opaque bearer is not an error — it just means this can add nothing, and
  // the failure reports what it always did.
  testSync("says nothing about a token it cannot read", () => {
    expect(clientWith("not-a-token")->Seed_Client.effectiveGroups)->toEqual(None)
    expect(
      Seed_Client.make(~config={endpoint: "http://example.invalid/graphql"})
      ->Seed_Client.effectiveGroups,
    )->toEqual(None)
  })
})

// The id an `@owner` field is stamped with. A seed that cannot read it can only
// key owner-scoped rows to a literal, and a literal matches one platform's
// accounts at most — which is how a demo shopper came to be registered on a
// deployment where nobody can ever be that shopper.

describe("Seed_Client.callerId:", () => {
  // A Cognito id token says `sub`; the local dev token is a base64url
  // `Identity.t`, whose field is `userId`. Neither platform announces which.
  testSync("reads the id under whichever name the provider gave it", () => {
    expect(
      clientWith(jwt([("sub", JSON.Encode.string("4275e4a4-00c1-70e1"))]))->Seed_Client.callerId,
    )->toEqual(Some("4275e4a4-00c1-70e1"))
    expect(
      clientWith(localToken([("userId", JSON.Encode.string("local-shopper"))]))
      ->Seed_Client.callerId,
    )->toEqual(Some("local-shopper"))
  })

  // `sub` first, so a token carrying both is read the way the pool that minted
  // it means it.
  testSync("prefers sub when a token carries both names", () =>
    expect(
      clientWith(
        jwt([
          ("sub", JSON.Encode.string("f215e4b4-30f1-700c")),
          ("userId", JSON.Encode.string("local-shopper")),
        ]),
      )->Seed_Client.callerId,
    )->toEqual(Some("f215e4b4-30f1-700c"))
  )

  // `None` is not an error — it means this cannot add anything, and the caller
  // falls back to whatever the accounts file declared.
  testSync("says nothing about a token it cannot read, or one naming no id", () => {
    expect(clientWith("not-a-token")->Seed_Client.callerId)->toEqual(None)
    expect(clientWith(jwt([("cognito:groups", strings(["Admin"]))]))->Seed_Client.callerId)
    ->toEqual(None)
    expect(
      Seed_Client.make(~config={endpoint: "http://example.invalid/graphql"})
      ->Seed_Client.callerId,
    )->toEqual(None)
  })

  // A claim of the wrong shape is not an id. Taking the array's first element
  // would be a guess, and a guessed owner id seeds rows nobody can read.
  testSync("refuses a claim that is not a single string", () =>
    expect(clientWith(jwt([("sub", strings(["a", "b"]))]))->Seed_Client.callerId)->toEqual(None)
  )
})

describe("Seed_Client.identitySummary:", () => {
  // The case that cost the debugging: eligible in the user list, refused by the
  // token. Naming what it was narrowed FROM is what points at the role switch.
  testSync("names the membership a narrowed token gave up", () =>
    expect(
      clientWith(
        jwt([
          ("cognito:groups", strings(["Shopper"])),
          ("availableRoles", JSON.Encode.string("Admin,Shopper")),
        ]),
      )->Seed_Client.identitySummary,
    )->toEqual(Some("Shopper — narrowed to this role from Admin, Shopper"))
  )

  // An ordinary login is not narrowed and has nothing to explain.
  testSync("stays quiet about an unnarrowed token", () =>
    expect(
      clientWith(jwt([("cognito:groups", strings(["Admin", "Shopper"]))]))
      ->Seed_Client.identitySummary,
    )->toEqual(Some("Admin, Shopper"))
  )

  // A token granting nothing reads as a sentence rather than an empty string.
  testSync("says so when the token carries no groups at all", () =>
    expect(
      clientWith(jwt([("cognito:groups", strings([]))]))->Seed_Client.identitySummary,
    )->toEqual(Some("no groups"))
  )
})

describe("Seed_Client.isDenied:", () => {
  // AppSync types it; the local server carries it in the message.
  testSync("recognises a refusal in either platform's vocabulary", () => {
    expect(Seed_Client.isDenied(errors([errorOfType("Unauthorized")])))->toBe(true)
    expect(
      Seed_Client.isDenied(
        errors([Dict.fromArray([("message", JSON.Encode.string("Not Authorized to access X"))])]),
      ),
    )->toBe(true)
  })

  // Attaching an identity to an unrelated failure would point the reader at the
  // wrong thing.
  testSync("leaves every other failure alone", () => {
    expect(Seed_Client.isDenied(errors([errorOfType("ValidationException")])))->toBe(false)
    expect(Seed_Client.isDenied(errors([])))->toBe(false)
  })
})
