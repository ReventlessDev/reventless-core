open JestGlobals

// The local identity provider over the accounts file. What matters is that the
// file and the running login store say the same thing after every operation,
// and that a process starting afresh from the file sees the account.

let email = address => Reventless.Messaging.ToEmail(Reventless.Email.unsafe(address))

let freshFile = (): string => {
  let dir = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "reventless-identity-"]))
  NodePath.join([dir, ".reventless", "users.yaml"])
}

let resetAll = () => {
  LocalAuth.resetUsers()
  LocalAuth.Login.resetStore()
  UserStore.resetResolution()
}

let restartFrom = (file: string): unit => {
  resetAll()
  switch UserStore.load(~usersFile=file, ()) {
  | Ok(_) => ()
  | Error(message) => JsError.throwWithMessage(`reload failed: ${message}`)
  }
}

describe("Capability_IdentityProvider_UserStore", () => {
  testSync("publishes all four operations", () =>
    expect(Capability_IdentityProvider_UserStore.make(~path=freshFile(), ()).operations)->toEqual([
      Reventless.IdentityProvider.CreatePrincipal,
      AddToGroup,
      RemoveFromGroup,
      DeletePrincipal,
    ])
  )

  testPromise("a created principal can log in now and after a restart", async () => {
    resetAll()
    let file = freshFile()
    let provider = Capability_IdentityProvider_UserStore.make(~path=file, ())
    let created = await provider.createPrincipal(
      ~contact=email("new@example.com"),
      ~credential=Password("secret-1"),
      ~groups=["Shopper"],
    )
    expect(created)->toEqual(Ok({Reventless.IdentityProvider.providerId: "new@example.com"}))
    expect(
      (await LocalAuth.Login.issue(~username="new@example.com", ~password="secret-1"))->Result.isOk,
    )->toBe(true)

    restartFrom(file)
    expect(
      (await LocalAuth.Login.issue(~username="new@example.com", ~password="secret-1"))->Result.isOk,
    )->toBe(true)
    expect(LocalAuth.lookupUser("new@example.com")->Option.map(i => i.groups))->toEqual(
      Some(["Shopper"]),
    )
  })

  testPromise("the same contact twice is a Conflict, not a second account", async () => {
    resetAll()
    let provider = Capability_IdentityProvider_UserStore.make(~path=freshFile(), ())
    let create = () =>
      provider.createPrincipal(
        ~contact=email("twice@example.com"),
        ~credential=NoCredential,
        ~groups=[],
      )
    let _ = await create()
    expect(await create())->toEqual(Error(Reventless.IdentityProvider.Conflict))
  })

  // An empty password is the manifest's "authenticates nowhere", so the account
  // exists for the next provisioning step without a credential anyone holds.
  testPromise("NoCredential writes an account no password opens", async () => {
    resetAll()
    let provider = Capability_IdentityProvider_UserStore.make(~path=freshFile(), ())
    let _ = await provider.createPrincipal(
      ~contact=email("later@example.com"),
      ~credential=NoCredential,
      ~groups=[],
    )
    expect(LocalAuth.lookupUser("later@example.com")->Option.isSome)->toBe(true)
    expect(
      (await LocalAuth.Login.issue(~username="later@example.com", ~password=""))->Result.isOk,
    )->toBe(true)
  })

  testPromise("a push address is refused, since nothing signs in with one", async () => {
    let provider = Capability_IdentityProvider_UserStore.make(~path=freshFile(), ())
    let answer = await provider.createPrincipal(
      ~contact=ToPush(Fcm({registrationToken: "tok"})),
      ~credential=NoCredential,
      ~groups=[],
    )
    expect(
      switch answer {
      | Error(Refused(_)) => true
      | _ => false
      },
    )->toBe(true)
  })

  testPromise("groups round-trip through the file", async () => {
    resetAll()
    let file = freshFile()
    let provider = Capability_IdentityProvider_UserStore.make(~path=file, ())
    let principal: Reventless.IdentityProvider.principal = {providerId: "grp@example.com"}
    let _ = await provider.createPrincipal(
      ~contact=email("grp@example.com"),
      ~credential=Password("pw"),
      ~groups=["Shopper"],
    )
    expect(await provider.addToGroup(~principal, ~group="Reviewer"))->toEqual(Ok())
    expect(await provider.addToGroup(~principal, ~group="Reviewer"))->toEqual(Ok())
    restartFrom(file)
    expect(LocalAuth.lookupUser("grp@example.com")->Option.map(i => i.groups))->toEqual(
      Some(["Shopper", "Reviewer"]),
    )
    expect(await provider.removeFromGroup(~principal, ~group="Shopper"))->toEqual(Ok())
    restartFrom(file)
    expect(LocalAuth.lookupUser("grp@example.com")->Option.map(i => i.groups))->toEqual(
      Some(["Reviewer"]),
    )
  })

  testPromise("grouping a principal that does not exist is refused", async () => {
    resetAll()
    let provider = Capability_IdentityProvider_UserStore.make(~path=freshFile(), ())
    let answer = await provider.addToGroup(~principal={providerId: "ghost"}, ~group="Shopper")
    expect(answer)->toEqual(Error(Reventless.IdentityProvider.Refused("no principal ghost")))
  })

  testPromise("deleting removes the account from the file and the login, twice", async () => {
    resetAll()
    let file = freshFile()
    let provider = Capability_IdentityProvider_UserStore.make(~path=file, ())
    let principal: Reventless.IdentityProvider.principal = {providerId: "gone@example.com"}
    let _ = await provider.createPrincipal(
      ~contact=email("gone@example.com"),
      ~credential=Password("pw"),
      ~groups=[],
    )
    expect(await provider.deletePrincipal(~principal))->toEqual(Ok())
    expect(LocalAuth.lookupUser("gone@example.com"))->toEqual(None)
    expect(await provider.deletePrincipal(~principal))->toEqual(Ok())
    restartFrom(file)
    expect(LocalAuth.lookupUser("gone@example.com"))->toEqual(None)
  })

  testPromise("the file's own comments survive every operation", async () => {
    resetAll()
    let file = freshFile()
    NodeFs.mkdirSync(NodePath.dirname(file), {recursive: true})
    NodeFs.writeFileSync(
      file,
      `- username: admin # keep this one
  password: pw
  groups: [Admin]
`,
    )
    let provider = Capability_IdentityProvider_UserStore.make(~path=file, ())
    let _ = await provider.createPrincipal(
      ~contact=email("c@example.com"),
      ~credential=Password("pw"),
      ~groups=[],
    )
    let _ = await provider.addToGroup(~principal={providerId: "c@example.com"}, ~group="Shopper")
    let _ = await provider.deletePrincipal(~principal={providerId: "c@example.com"})
    expect(NodeFs.readFileSync(file)->String.includes("# keep this one"))->toBe(true)
  })
})
