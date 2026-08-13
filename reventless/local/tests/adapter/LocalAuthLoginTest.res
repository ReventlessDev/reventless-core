// Stage A4 — LocalAuth.Login (token issuance) + Bearer-token recognition
// in LocalAuth.authenticate.

@@warning("-44")

open JestGlobals

let alice: Reventless.Identity.t = {
  userId: "u-alice",
  username: "alice",
  groups: ["Editor"],
  provider: InMemory,
}

let bob: Reventless.Identity.t = {
  userId: "u-bob",
  username: "bob",
  groups: ["Viewer"],
  provider: InMemory,
}

let buildContext = (headers: array<(string, string)>): ReventlessCore.Auth_Adapter.requestContext => {
  headers: Dict.fromArray(headers),
}

let resetAll = () => {
  LocalAuth.resetUsers()
  LocalAuth.Login.resetStore()
  LocalAuth.Login.setTokenSecret("test-secret-deterministic")
}

testPromise("issue returns Ok(token) for valid credentials", async () => {
  resetAll()
  LocalAuth.Login.setCredentials(~username="alice", ~password="alice-pw", ~identity=alice)
  let result = await LocalAuth.Login.issue(~username="alice", ~password="alice-pw")
  switch result {
  | Ok(token) =>
    // Token shape: <base64url-payload>.<base64url-sig>
    let parts = token->String.split(".")
    expect(parts->Array.length)->toEqual(2)
  | Error(msg) => JsError.throwWithMessage("unexpected Error: " ++ msg)
  }
})

testPromise("issue returns Error for unknown username", async () => {
  resetAll()
  let result = await LocalAuth.Login.issue(~username="ghost", ~password="x")
  switch result {
  | Error(_) => ()
  | Ok(_) => JsError.throwWithMessage("expected Error")
  }
})

testPromise("issue returns Error for wrong password", async () => {
  resetAll()
  LocalAuth.Login.setCredentials(~username="alice", ~password="alice-pw", ~identity=alice)
  let result = await LocalAuth.Login.issue(~username="alice", ~password="WRONG")
  switch result {
  | Error(_) => ()
  | Ok(_) => JsError.throwWithMessage("expected Error")
  }
})

testPromise("verifyAndDecode round-trips the identity for a fresh token", async () => {
  resetAll()
  LocalAuth.Login.setCredentials(~username="alice", ~password="alice-pw", ~identity=alice)
  let token = switch await LocalAuth.Login.issue(~username="alice", ~password="alice-pw") {
  | Ok(t) => t
  | Error(msg) => JsError.throwWithMessage("issue failed: " ++ msg)
  }
  switch LocalAuth.Login.verifyAndDecode(token) {
  | Some(identity) =>
    expect(identity.username)->toEqual("alice")
    expect(identity.groups)->toEqual(["Editor"])
    expect(identity.userId)->toEqual("u-alice")
  | None => JsError.throwWithMessage("verifyAndDecode returned None")
  }
})

testPromise("verifyAndDecode rejects a tampered payload", async () => {
  resetAll()
  LocalAuth.Login.setCredentials(~username="alice", ~password="alice-pw", ~identity=alice)
  let token = switch await LocalAuth.Login.issue(~username="alice", ~password="alice-pw") {
  | Ok(t) => t
  | Error(msg) => JsError.throwWithMessage("issue failed: " ++ msg)
  }
  // Flip the first character of the payload — signature should no longer verify.
  let parts = token->String.split(".")
  let payload = parts->Array.getUnsafe(0)
  let sig = parts->Array.getUnsafe(1)
  let firstChar = payload->String.charAt(0)
  let replacement = firstChar == "A" ? "B" : "A"
  let tamperedPayload = replacement ++ payload->String.slice(~start=1, ~end=payload->String.length)
  let tampered = `${tamperedPayload}.${sig}`
  switch LocalAuth.Login.verifyAndDecode(tampered) {
  | None => ()
  | Some(_) => JsError.throwWithMessage("expected verifyAndDecode to reject tampered payload")
  }
})

testPromise("verifyAndDecode rejects a tampered signature", async () => {
  resetAll()
  LocalAuth.Login.setCredentials(~username="alice", ~password="alice-pw", ~identity=alice)
  let token = switch await LocalAuth.Login.issue(~username="alice", ~password="alice-pw") {
  | Ok(t) => t
  | Error(msg) => JsError.throwWithMessage("issue failed: " ++ msg)
  }
  // Append a junk char to the signature.
  switch LocalAuth.Login.verifyAndDecode(token ++ "x") {
  | None => ()
  | Some(_) => JsError.throwWithMessage("expected verifyAndDecode to reject tampered signature")
  }
})

testPromise("verifyAndDecode rejects a malformed token (no dot)", async () => {
  resetAll()
  switch LocalAuth.Login.verifyAndDecode("not-a-real-token") {
  | None => ()
  | Some(_) => JsError.throwWithMessage("expected None for malformed token")
  }
})

testPromise("authenticate accepts a valid Bearer token", async () => {
  resetAll()
  LocalAuth.Login.setCredentials(~username="bob", ~password="bob-pw", ~identity=bob)
  let token = switch await LocalAuth.Login.issue(~username="bob", ~password="bob-pw") {
  | Ok(t) => t
  | Error(msg) => JsError.throwWithMessage("issue failed: " ++ msg)
  }
  let result = await LocalAuth.authenticate(
    buildContext([("authorization", "Bearer " ++ token)]),
  )
  switch result {
  | Authenticated(identity) =>
    expect(identity.username)->toEqual("bob")
    expect(identity.groups)->toEqual(["Viewer"])
  | _ => JsError.throwWithMessage("expected Authenticated(bob)")
  }
})

testPromise("authenticate rejects invalid Bearer even when X-User is present", async () => {
  resetAll()
  // A present-but-unverifiable Bearer must reject with AuthError so the
  // host-shell `on401` logout path fires. X-User is ignored.
  let result = await LocalAuth.authenticate(
    buildContext([("authorization", "Bearer not-a-token"), ("x-user", "admin")]),
  )
  switch result {
  | AuthError(_) => ()
  | _ => JsError.throwWithMessage("expected AuthError for invalid Bearer")
  }
})

testPromise("Bearer outranks X-User when both present and Bearer is valid", async () => {
  resetAll()
  LocalAuth.Login.setCredentials(~username="bob", ~password="bob-pw", ~identity=bob)
  let token = switch await LocalAuth.Login.issue(~username="bob", ~password="bob-pw") {
  | Ok(t) => t
  | Error(msg) => JsError.throwWithMessage("issue failed: " ++ msg)
  }
  let result = await LocalAuth.authenticate(
    buildContext([("authorization", "Bearer " ++ token), ("x-user", "admin")]),
  )
  switch result {
  | Authenticated(identity) => expect(identity.username)->toEqual("bob")
  | _ => JsError.throwWithMessage("expected Bearer to outrank X-User")
  }
})

testPromise("setCredentials mirrors identity into the X-User registry", async () => {
  resetAll()
  LocalAuth.Login.setCredentials(~username="alice", ~password="alice-pw", ~identity=alice)
  let result = await LocalAuth.authenticate(buildContext([("x-user", "alice")]))
  switch result {
  | Authenticated(identity) =>
    expect(identity.userId)->toEqual("u-alice")
    expect(identity.groups)->toEqual(["Editor"])
  | _ => JsError.throwWithMessage("expected Authenticated(alice) via X-User")
  }
})

// ── Acting as one of the roles you hold ───────────────────────────────────
//
// The subset rule is the security-critical line of the feature: narrowing only,
// never widening, so a client that tampers with the request can only ever reduce
// its own privilege. The table below is the same one the Cognito minting path
// has to satisfy — the two implementations cannot be shared across a process
// boundary, so the cases are what keeps them from drifting.

let multiRole: Reventless.Identity.t = {
  userId: "u-carol",
  username: "carol",
  groups: ["Fulfilment", "Shopper"],
  provider: InMemory,
}

let decodeOrThrow = token =>
  switch LocalAuth.Login.verifyAndDecode(token) {
  | Some(i) => i
  | None => JsError.throwWithMessage("expected a verifiable token")
  }

let carolLoggedIn = () => {
  resetAll()
  LocalAuth.Login.setCredentials(~username="carol", ~password="carol-pw", ~identity=multiRole)
}

// The regression line. Every login that existed before this feature takes this
// path, and it has to mint what it always minted.
testPromise("a login naming no role mints exactly what it minted before", async () => {
  carolLoggedIn()
  let plain = switch await LocalAuth.Login.issue(~username="carol", ~password="carol-pw") {
  | Ok(t) => t
  | Error(e) => JsError.throwWithMessage(e)
  }
  let identity = decodeOrThrow(plain)
  expect(identity.groups)->toEqual(["Fulfilment", "Shopper"])
  expect(identity.claims)->toEqual(None)
})

testPromise("a login naming a held role mints that role alone", async () => {
  carolLoggedIn()
  let token = switch await LocalAuth.Login.issue(
    ~username="carol",
    ~password="carol-pw",
    ~activeRole="Shopper",
  ) {
  | Ok(t) => t
  | Error(e) => JsError.throwWithMessage(e)
  }
  let identity = decodeOrThrow(token)
  // `groups` is what every enforcement point reads, so this is the assertion
  // that the narrowing is real rather than cosmetic.
  expect(identity.groups)->toEqual(["Shopper"])
})

testPromise("a narrowed token remembers the choice and what it gave up", async () => {
  carolLoggedIn()
  let token = switch await LocalAuth.Login.issue(
    ~username="carol",
    ~password="carol-pw",
    ~activeRole="Shopper",
  ) {
  | Ok(t) => t
  | Error(e) => JsError.throwWithMessage(e)
  }
  let identity = decodeOrThrow(token)
  expect((
    identity->Reventless.Identity.getClaim("activeRole"),
    identity->Reventless.Identity.getClaim("availableRoles"),
  ))->toEqual((Some("Shopper"), Some("Fulfilment,Shopper")))
})

// The line that decides whether this is a security feature or a suggestion.
// Refused, specifically — not ignored and minted at full membership, which is
// the failure that would hand a tampering client everything it asked for.
testPromise("a login naming a role the user does not hold is REFUSED", async () => {
  carolLoggedIn()
  switch await LocalAuth.Login.issue(
    ~username="carol",
    ~password="carol-pw",
    ~activeRole="Admin",
  ) {
  | Ok(_) => JsError.throwWithMessage("expected a request to widen to be refused")
  | Error(msg) => expect(msg->String.includes("Admin"))->toEqual(true)
  }
})

// Narrowing to a role you hold while *also* naming one you do not is the same
// widening attempt wearing a disguise; there is no partial credit.
testPromise("narrowing cannot smuggle a group in through the claims bag", async () => {
  resetAll()
  let withClaims: Reventless.Identity.t = {
    ...multiRole,
    claims: Dict.fromArray([("availableRoles", "Admin,Fulfilment,Shopper")]),
  }
  LocalAuth.Login.setCredentials(~username="carol", ~password="carol-pw", ~identity=withClaims)
  switch await LocalAuth.Login.issue(
    ~username="carol",
    ~password="carol-pw",
    ~activeRole="Admin",
  ) {
  | Ok(_) =>
    JsError.throwWithMessage("expected membership to be judged by groups, not by a claim")
  | Error(_) => expect(true)->toEqual(true)
  }
})

// A narrowed token has to survive the same round trip an ordinary one does, or
// the narrowing would hold only until the next request.
testPromise("a narrowed token authenticates as the narrowed identity", async () => {
  carolLoggedIn()
  let token = switch await LocalAuth.Login.issue(
    ~username="carol",
    ~password="carol-pw",
    ~activeRole="Shopper",
  ) {
  | Ok(t) => t
  | Error(e) => JsError.throwWithMessage(e)
  }
  let result = await LocalAuth.authenticate(
    buildContext([("authorization", "Bearer " ++ token)]),
  )
  switch result {
  | Authenticated(identity) => expect(identity.groups)->toEqual(["Shopper"])
  | _ => JsError.throwWithMessage("expected the narrowed token to authenticate")
  }
})

// The login response echoes this, and it has to describe the token it ships
// beside rather than the account behind it.
testPromise("the minted identity matches the token, not the stored user", async () => {
  carolLoggedIn()
  let minted = LocalAuth.Login.mintedIdentity(~username="carol", ~activeRole=Some("Shopper"))
  let stored = LocalAuth.lookupUser("carol")
  expect((
    minted->Option.mapOr([], i => i.groups),
    stored->Option.mapOr([], i => i.groups),
  ))->toEqual((["Shopper"], ["Fulfilment", "Shopper"]))
})

// ── Switching an existing session ─────────────────────────────────────────
//
// A switch is not a re-authentication: the client holds a token, not a
// password. Possession of a token this server signed is proof of the
// credentials that produced it, so the switch re-mints from the token — and
// re-reads membership from the store, never from the token's own record of it.

testPromise("a session can be re-minted as one of its roles", async () => {
  carolLoggedIn()
  let wide = switch await LocalAuth.Login.issue(~username="carol", ~password="carol-pw") {
  | Ok(t) => t
  | Error(e) => JsError.throwWithMessage(e)
  }
  switch LocalAuth.Login.reissue(~token=wide, ~activeRole=Some("Shopper")) {
  | Ok(t) => expect(decodeOrThrow(t).groups)->toEqual(["Shopper"])
  | Error(e) => JsError.throwWithMessage(e)
  }
})

// Switching back is the other half of a switcher, and it is not an escalation:
// the set being widened to is the one the store says the caller holds.
testPromise("a narrowed session can widen back to its full membership", async () => {
  carolLoggedIn()
  let narrow = switch await LocalAuth.Login.issue(
    ~username="carol",
    ~password="carol-pw",
    ~activeRole="Shopper",
  ) {
  | Ok(t) => t
  | Error(e) => JsError.throwWithMessage(e)
  }
  switch LocalAuth.Login.reissue(~token=narrow, ~activeRole=None) {
  | Ok(t) =>
    let identity = decodeOrThrow(t)
    expect((identity.groups, identity.claims))->toEqual((["Fulfilment", "Shopper"], None))
  | Error(e) => JsError.throwWithMessage(e)
  }
})

// 🚨 The assertion that keeps `availableRoles` from becoming an authority. A
// narrowed token carries the record of what it gave up; if the switch trusted
// that record instead of the store, a token forged with a wider claim — or a
// role revoked since issuance — would widen right back into it.
testPromise("switching judges membership from the store, not the token's claim", async () => {
  carolLoggedIn()
  let narrow = switch await LocalAuth.Login.issue(
    ~username="carol",
    ~password="carol-pw",
    ~activeRole="Shopper",
  ) {
  | Ok(t) => t
  | Error(e) => JsError.throwWithMessage(e)
  }
  // The store loses the role while the token still remembers it.
  LocalAuth.Login.setCredentials(
    ~username="carol",
    ~password="carol-pw",
    ~identity={...multiRole, groups: ["Shopper"]},
  )
  switch LocalAuth.Login.reissue(~token=narrow, ~activeRole=Some("Fulfilment")) {
  | Ok(_) =>
    JsError.throwWithMessage("expected a revoked role to be unreachable via the token's claim")
  | Error(_) => expect(true)->toEqual(true)
  }
})

testPromise("switching refuses a token this server did not sign", async () => {
  carolLoggedIn()
  switch LocalAuth.Login.reissue(~token="not.a-real-token", ~activeRole=Some("Shopper")) {
  | Ok(_) => JsError.throwWithMessage("expected an unverifiable token to be refused")
  | Error(msg) => expect(msg)->toEqual("Invalid token")
  }
})

// ── The shared conformance table ──────────────────────────────────────────
//
// The cases above were written against this path. `ReventlessCore.Auth_ActiveRole`
// holds them in a form the Cognito path runs too — the two minting
// implementations cannot share code across a process boundary, so a table both
// drive is what keeps them from drifting. A case added there fails here until
// this path satisfies it, which is the point.

describe("the conformance table, minted locally", () => {
  ReventlessCore.Auth_ActiveRole.conformanceCases->Array.forEach(({
    label,
    membership,
    requested,
    expected,
  }) =>
    testPromise(label, async () => {
      resetAll()
      LocalAuth.Login.setCredentials(
        ~username="conformance",
        ~password="pw",
        ~identity={
          userId: "u-conformance",
          username: "conformance",
          groups: membership,
          provider: InMemory,
        },
      )
      let minted = await LocalAuth.Login.issue(
        ~username="conformance",
        ~password="pw",
        ~activeRole=?requested,
      )
      switch (minted, expected) {
      | (Ok(token), Some(groups)) => expect(decodeOrThrow(token).groups)->toEqual(groups)
      // `None` means refused — not honoured, not ignored, and not reduced to the
      // empty set. A token minted here at all would be the vulnerability.
      | (Ok(_), None) => JsError.throwWithMessage("expected the request to be refused")
      | (Error(msg), Some(_)) => JsError.throwWithMessage("expected a token, got: " ++ msg)
      | (Error(_), None) => expect(true)->toEqual(true)
      }
    })
  )
})
