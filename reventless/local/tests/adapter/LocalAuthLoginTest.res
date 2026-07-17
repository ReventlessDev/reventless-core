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
