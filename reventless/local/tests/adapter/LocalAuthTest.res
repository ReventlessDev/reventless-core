// Extraction matrix for LocalAuth.authenticate. Each test resets the
// user registry first so cross-test mutation in registerUser doesn't leak.

@@warning("-44")

open JestGlobals

let buildContext = (headers: array<(string, string)>): ReventlessCore.Auth_Adapter.requestContext => {
  headers: Dict.fromArray(headers),
}

testPromise("no X-User, no X-Groups → defaultUser (in-memory dev convenience)", async () => {
  LocalAuth.resetUsers()
  let result = await LocalAuth.authenticate(buildContext([]))
  switch result {
  | Authenticated(identity) =>
    expect(identity.username)->toEqual("user")
    expect(identity.groups)->toEqual(["User"])
  | _ => JsError.throwWithMessage("expected Authenticated(defaultUser)")
  }
})

testPromise("X-User: admin resolves built-in admin identity", async () => {
  LocalAuth.resetUsers()
  let result = await LocalAuth.authenticate(
    buildContext([("x-user", "admin")]),
  )
  switch result {
  | Authenticated(identity) =>
    expect(identity.username)->toEqual("admin")
    expect(identity.groups)->toEqual(["Admin", "User"])
  | _ => JsError.throwWithMessage("expected Authenticated")
  }
})

testPromise("X-User: user resolves built-in default identity", async () => {
  LocalAuth.resetUsers()
  let result = await LocalAuth.authenticate(
    buildContext([("x-user", "user")]),
  )
  switch result {
  | Authenticated(identity) =>
    expect(identity.username)->toEqual("user")
    expect(identity.groups)->toEqual(["User"])
  | _ => JsError.throwWithMessage("expected Authenticated")
  }
})

testPromise("unknown X-User falls back to Anonymous", async () => {
  LocalAuth.resetUsers()
  let result = await LocalAuth.authenticate(
    buildContext([("x-user", "unknown")]),
  )
  switch result {
  | Anonymous => ()
  | _ => JsError.throwWithMessage("expected Anonymous")
  }
})

testPromise("X-Groups overrides the resolved identity's groups", async () => {
  LocalAuth.resetUsers()
  let result = await LocalAuth.authenticate(
    buildContext([("x-user", "admin"), ("x-groups", "Editor, Viewer")]),
  )
  switch result {
  | Authenticated(identity) =>
    expect(identity.username)->toEqual("admin")
    expect(identity.groups)->toEqual(["Editor", "Viewer"])
  | _ => JsError.throwWithMessage("expected Authenticated")
  }
})

testPromise("X-Groups alone yields defaultUser tagged with the override groups", async () => {
  LocalAuth.resetUsers()
  let result = await LocalAuth.authenticate(
    buildContext([("x-groups", "Tester")]),
  )
  switch result {
  | Authenticated(identity) =>
    expect(identity.userId)->toEqual("local-user")
    expect(identity.groups)->toEqual(["Tester"])
  | _ => JsError.throwWithMessage("expected Authenticated")
  }
})

testPromise("registerUser injects a custom identity", async () => {
  LocalAuth.resetUsers()
  LocalAuth.registerUser(
    ~username="alice",
    ~identity={
      userId: "alice-id",
      username: "alice",
      groups: ["Editor"],
      provider: InMemory,
    },
  )
  let result = await LocalAuth.authenticate(
    buildContext([("x-user", "alice")]),
  )
  switch result {
  | Authenticated(identity) =>
    expect(identity.userId)->toEqual("alice-id")
    expect(identity.groups)->toEqual(["Editor"])
  | _ => JsError.throwWithMessage("expected Authenticated")
  }
})
