// Stage A4 — AccountStore.load resolution order and YAML parsing.

@@warning("-44")

open JestGlobals

let resetAll = () => {
  LocalAuth.resetUsers()
  LocalAuth.Login.resetStore()
  AccountStore.resetResolution()
}

let _writeYamlFile = (contents: string): string => {
  let dir = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "reventless-userstore-"]))
  let path = NodePath.join([dir, "accounts.yaml"])
  NodeFs.writeFileSync(path, contents)
  path
}

testPromise("parseString decodes a well-formed YAML document", async () => {
  let yaml = `
- username: alice
  password: alice-pw
  groups: [Editor]
- username: bob
  password: bob-pw
  groups: []
`
  switch AccountStore.parseString(yaml) {
  | Ok(entries) =>
    expect(entries->Array.length)->toEqual(2)
    let first = entries->Array.getUnsafe(0)
    expect(first.username)->toEqual("alice")
    expect(first.password)->toEqual("alice-pw")
    expect(first.groups)->toEqual(["Editor"])
  | Error(msg) => JsError.throwWithMessage("parseString failed: " ++ msg)
  }
})

testPromise("parseString rejects malformed YAML", async () => {
  switch AccountStore.parseString("not: valid: yaml: at all: ::") {
  | Error(_) => ()
  | Ok(_) => JsError.throwWithMessage("expected Error for malformed YAML")
  }
})

testPromise("parseString rejects entries missing required fields", async () => {
  let yaml = `
- username: alice
  groups: [Editor]
`
  switch AccountStore.parseString(yaml) {
  | Error(_) => ()
  | Ok(_) => JsError.throwWithMessage("expected Error for missing password")
  }
})

testPromise("load(~accounts) registers credentials and returns InlineAccounts", async () => {
  resetAll()
  let entries: array<AccountStore.entry> = [
    {username: "alice", password: "alice-pw", groups: ["Editor"]},
    {username: "bob", password: "bob-pw", groups: [], userId: "u-bob"},
  ]
  switch AccountStore.load(~accounts=entries, ()) {
  | Ok(InlineAccounts) => ()
  | Ok(_) => JsError.throwWithMessage("expected InlineAccounts")
  | Error(msg) => JsError.throwWithMessage("load failed: " ++ msg)
  }
  // Verify Login.issue accepts the credentials.
  let result = await LocalAuth.Login.issue(~username="alice", ~password="alice-pw")
  switch result {
  | Ok(_) => ()
  | Error(msg) => JsError.throwWithMessage("issue rejected loaded credentials: " ++ msg)
  }
  // userId override is honored.
  switch LocalAuth.lookupUser("bob") {
  | Some(identity) => expect(identity.userId)->toEqual("u-bob")
  | None => JsError.throwWithMessage("bob not in user registry")
  }
})

testPromise("load(~accountsFile) reads a YAML file from disk", async () => {
  resetAll()
  let path = _writeYamlFile(`
- username: carol
  password: carol-pw
  groups: [Admin]
`)
  switch AccountStore.load(~accountsFile=path, ()) {
  | Ok(AccountsFile(p)) => expect(p)->toEqual(path)
  | Ok(_) => JsError.throwWithMessage("expected AccountsFile resolution")
  | Error(msg) => JsError.throwWithMessage("load failed: " ++ msg)
  }
  let result = await LocalAuth.Login.issue(~username="carol", ~password="carol-pw")
  switch result {
  | Ok(_) => ()
  | Error(msg) => JsError.throwWithMessage("issue rejected file-loaded credentials: " ++ msg)
  }
  NodeFs.rmSync(path, {force: true})
})

testPromise("load(~accountsFile) returns Error when the file is missing", async () => {
  resetAll()
  switch AccountStore.load(~accountsFile="/tmp/does-not-exist-reventless.yaml", ()) {
  | Error(_) => ()
  | Ok(_) => JsError.throwWithMessage("expected Error for missing file")
  }
})

testPromise("load() with no args + no default file returns Empty", async () => {
  resetAll()
  // The test's cwd has no .reventless/accounts.yaml — verify Empty is returned.
  // (The package's own cwd is reventless-local/ during `pnpm test`, where
  // no such file exists.)
  switch AccountStore.load() {
  | Ok(Empty) => ()
  | Ok(DefaultFile(_)) => // If a .reventless/accounts.yaml happens to exist in CI, accept it.
    ()
  | Ok(_) => JsError.throwWithMessage("expected Empty or DefaultFile")
  | Error(msg) => JsError.throwWithMessage("load failed: " ++ msg)
  }
})

testPromise("inline users win over a file path", async () => {
  resetAll()
  let path = _writeYamlFile(`
- username: file-user
  password: file-pw
  groups: []
`)
  let inline: array<AccountStore.entry> = [
    {username: "inline-user", password: "inline-pw", groups: []},
  ]
  switch AccountStore.load(~accounts=inline, ~accountsFile=path, ()) {
  | Ok(InlineAccounts) => ()
  | Ok(_) => JsError.throwWithMessage("expected InlineAccounts (inline should win)")
  | Error(msg) => JsError.throwWithMessage("load failed: " ++ msg)
  }
  // file-user must NOT be in the registry.
  switch LocalAuth.lookupUser("file-user") {
  | None => ()
  | Some(_) => JsError.throwWithMessage("file-user leaked into registry despite inline override")
  }
  switch LocalAuth.lookupUser("inline-user") {
  | Some(_) => ()
  | None => JsError.throwWithMessage("inline-user missing from registry")
  }
  NodeFs.rmSync(path, {force: true})
})

testPromise("autoLoadOnce is a no-op after an explicit load", async () => {
  resetAll()
  let _ = AccountStore.load(~accounts=[{username: "x", password: "x", groups: []}], ())
  // Second call should not crash even if .reventless/accounts.yaml doesn't
  // exist; resolved=true prevents the default-discovery branch.
  AccountStore.autoLoadOnce()
  // Sanity: explicit-load registration persists.
  switch LocalAuth.lookupUser("x") {
  | Some(_) => ()
  | None => JsError.throwWithMessage("autoLoadOnce wiped explicit registration")
  }
})

// What the role check counts as provided, before the servers load the store.
describe("AccountStore.providedGroups", () => {
  // Runs `f` in a directory holding `files` (path relative to it → contents).
  let inDir = (files: array<(string, string)>, f) => {
    let dir = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "reventless-provided-"]))
    files->Array.forEach(((file, contents)) => {
      let path = NodePath.join([dir, file])
      NodeFs.mkdirSync(NodePath.dirname(path), {recursive: true})
      NodeFs.writeFileSync(path, contents)
    })
    let cwd = NodeProcess.cwd()
    NodeProcess.chdir(dir)
    let result = try f() catch {
    | exn =>
      NodeProcess.chdir(cwd)
      throw(exn)
    }
    NodeProcess.chdir(cwd)
    NodeFs.rmSync(dir, {recursive: true, force: true})
    result
  }
  let manifest = group => `- username: m\n  password: m\n  groups: [${group}]\n`
  let has = (group, groups) => groups->Array.includes(group)

  testSync("counts the default file the servers will load", () => {
    resetAll()
    let groups = inDir(
      [(".reventless/accounts.yaml", manifest("Merchandiser"))],
      () => AccountStore.providedGroups(),
    )
    expect(has("Merchandiser", groups))->toBe(true)
  })

  testSync("counts the template where setup has not made the file yet", () => {
    resetAll()
    let groups = inDir(
      [("accounts.example.yaml", manifest("Fulfilment"))],
      () => AccountStore.providedGroups(),
    )
    expect(has("Fulfilment", groups))->toBe(true)
  })

  testSync("once loaded from elsewhere, counts those accounts and not the directory's", () => {
    resetAll()
    let _ = AccountStore.load(~accounts=[{username: "i", password: "i", groups: ["Inline"]}], ())
    let groups = inDir(
      [(".reventless/accounts.yaml", manifest("Merchandiser"))],
      () => AccountStore.providedGroups(),
    )
    expect((has("Inline", groups), has("Merchandiser", groups)))->toEqual((true, false))
  })

  testSync("loading other accounts after a plugin was checked is refused", () => {
    resetAll()
    AccountStore.pluginChecked := true
    let refused = switch AccountStore.load(
      ~accounts=[{username: "late", password: "l", groups: ["Late"]}],
      (),
    ) {
    | _ => false
    | exception JsExn(_) => true
    }
    expect(refused)->toBe(true)
  })

  testSync("the default load after a plugin was checked is the one the check read", () => {
    resetAll()
    AccountStore.pluginChecked := true
    let loaded = inDir([], () => AccountStore.load()->Result.isOk)
    expect(loaded)->toBe(true)
  })
})

describe("AccountStore.reload", () => {
  let signsIn = async (~username, ~password) =>
    switch await LocalAuth.Login.issue(~username, ~password) {
    | Ok(_) => true
    | Error(_) => false
    }

  testPromise("adds, changes and forgets accounts as the file now says", async () => {
    resetAll()
    let path = _writeYamlFile(`
- username: alice
  password: a1
  groups: [Editor]
- username: bob
  password: b1
  groups: []
`)
    let _ = AccountStore.load(~accountsFile=path, ())
    NodeFs.writeFileSync(
      path,
      `
- username: alice
  password: a2
  groups: [Editor]
- username: driver
  password: driver
  groups: [Driver]
`,
    )
    switch AccountStore.reload(path) {
    | Ok(said) => expect(said)->toEqual("2 accounts, removed: bob")
    | Error(e) => JsError.throwWithMessage(e)
    }
    expect(await signsIn(~username="driver", ~password="driver"))->toBe(true)
    expect(await signsIn(~username="alice", ~password="a2"))->toBe(true)
    expect(await signsIn(~username="alice", ~password="a1"))->toBe(false)
    expect(await signsIn(~username="bob", ~password="b1"))->toBe(false)
    expect(LocalAuth.lookupUser("bob"))->toEqual(None)
  })

  testPromise("a file that does not parse changes nothing", async () => {
    resetAll()
    let path = _writeYamlFile(`
- username: alice
  password: a1
  groups: [Editor]
`)
    let _ = AccountStore.load(~accountsFile=path, ())
    NodeFs.writeFileSync(path, "- username: alice\n  groups: [Editor]\n")
    expect(AccountStore.reload(path)->Result.isError)->toBe(true)
    expect(await signsIn(~username="alice", ~password="a1"))->toBe(true)
  })

  testPromise("watch reads the file again once it is saved", async () => {
    resetAll()
    let path = _writeYamlFile(`
- username: alice
  password: a1
  groups: [Editor]
`)
    let _ = AccountStore.load(~accountsFile=path, ())
    AccountStore.watch(path)
    NodeFs.writeFileSync(
      path,
      `
- username: alice
  password: a1
  groups: [Editor]
- username: driver
  password: driver
  groups: [Driver]
`,
    )
    let rec waitFor = async (tries: int) =>
      if await signsIn(~username="driver", ~password="driver") {
        true
      } else if tries == 0 {
        false
      } else {
        await Promise.make((resolve, _) => setTimeout(() => resolve(), 50)->ignore)
        await waitFor(tries - 1)
      }
    let added = await waitFor(60)
    AccountStore.unwatch()
    expect(added)->toBe(true)
  })
})
