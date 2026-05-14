// Stage A4 — UserStore.load resolution order and YAML parsing.

@@warning("-44")

open AsyncTest
open AsyncTest.Expect

@module("node:fs") external _writeFileSync: (string, string, string) => unit = "writeFileSync"
@module("node:fs") external _mkdtempSync: string => string = "mkdtempSync"
@module("node:fs") external _rmSync: (string, {..}) => unit = "rmSync"
@module("node:path") external _join: (string, string) => string = "join"
@module("node:os") external _tmpdir: unit => string = "tmpdir"

let resetAll = () => {
  Auth_InMemory.resetUsers()
  Auth_InMemory.Login.resetStore()
  UserStore.resetResolution()
}

let _writeYamlFile = (contents: string): string => {
  let dir = _mkdtempSync(_join(_tmpdir(), "reventless-userstore-"))
  let path = _join(dir, "users.yaml")
  _writeFileSync(path, contents, "utf8")
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
  switch UserStore.parseString(yaml) {
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
  switch UserStore.parseString("not: valid: yaml: at all: ::") {
  | Error(_) => ()
  | Ok(_) => JsError.throwWithMessage("expected Error for malformed YAML")
  }
})

testPromise("parseString rejects entries missing required fields", async () => {
  let yaml = `
- username: alice
  groups: [Editor]
`
  switch UserStore.parseString(yaml) {
  | Error(_) => ()
  | Ok(_) => JsError.throwWithMessage("expected Error for missing password")
  }
})

testPromise("load(~users) registers credentials and returns InlineUsers", async () => {
  resetAll()
  let entries: array<UserStore.entry> = [
    {username: "alice", password: "alice-pw", groups: ["Editor"]},
    {username: "bob", password: "bob-pw", groups: [], userId: "u-bob"},
  ]
  switch UserStore.load(~users=entries, ()) {
  | Ok(InlineUsers) => ()
  | Ok(_) => JsError.throwWithMessage("expected InlineUsers")
  | Error(msg) => JsError.throwWithMessage("load failed: " ++ msg)
  }
  // Verify Login.issue accepts the credentials.
  let result = await Auth_InMemory.Login.issue(~username="alice", ~password="alice-pw")
  switch result {
  | Ok(_) => ()
  | Error(msg) => JsError.throwWithMessage("issue rejected loaded credentials: " ++ msg)
  }
  // userId override is honored.
  switch Auth_InMemory.lookupUser("bob") {
  | Some(identity) => expect(identity.userId)->toEqual("u-bob")
  | None => JsError.throwWithMessage("bob not in user registry")
  }
})

testPromise("load(~usersFile) reads a YAML file from disk", async () => {
  resetAll()
  let path = _writeYamlFile(`
- username: carol
  password: carol-pw
  groups: [Admin]
`)
  switch UserStore.load(~usersFile=path, ()) {
  | Ok(UsersFile(p)) => expect(p)->toEqual(path)
  | Ok(_) => JsError.throwWithMessage("expected UsersFile resolution")
  | Error(msg) => JsError.throwWithMessage("load failed: " ++ msg)
  }
  let result = await Auth_InMemory.Login.issue(~username="carol", ~password="carol-pw")
  switch result {
  | Ok(_) => ()
  | Error(msg) => JsError.throwWithMessage("issue rejected file-loaded credentials: " ++ msg)
  }
  _rmSync(path, {"force": true})
})

testPromise("load(~usersFile) returns Error when the file is missing", async () => {
  resetAll()
  switch UserStore.load(~usersFile="/tmp/does-not-exist-reventless.yaml", ()) {
  | Error(_) => ()
  | Ok(_) => JsError.throwWithMessage("expected Error for missing file")
  }
})

testPromise("load() with no args + no default file returns Empty", async () => {
  resetAll()
  // The test's cwd has no .reventless/users.yaml — verify Empty is returned.
  // (The package's own cwd is reventless-in-memory/ during `pnpm test`, where
  // no such file exists.)
  switch UserStore.load() {
  | Ok(Empty) => ()
  | Ok(DefaultFile(_)) =>
    // If a .reventless/users.yaml happens to exist in CI, accept it.
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
  let inline: array<UserStore.entry> = [
    {username: "inline-user", password: "inline-pw", groups: []},
  ]
  switch UserStore.load(~users=inline, ~usersFile=path, ()) {
  | Ok(InlineUsers) => ()
  | Ok(_) => JsError.throwWithMessage("expected InlineUsers (inline should win)")
  | Error(msg) => JsError.throwWithMessage("load failed: " ++ msg)
  }
  // file-user must NOT be in the registry.
  switch Auth_InMemory.lookupUser("file-user") {
  | None => ()
  | Some(_) => JsError.throwWithMessage("file-user leaked into registry despite inline override")
  }
  switch Auth_InMemory.lookupUser("inline-user") {
  | Some(_) => ()
  | None => JsError.throwWithMessage("inline-user missing from registry")
  }
  _rmSync(path, {"force": true})
})

testPromise("autoLoadOnce is a no-op after an explicit load", async () => {
  resetAll()
  let _ = UserStore.load(
    ~users=[{username: "x", password: "x", groups: []}],
    (),
  )
  // Second call should not crash even if .reventless/users.yaml doesn't
  // exist; resolved=true prevents the default-discovery branch.
  UserStore.autoLoadOnce()
  // Sanity: explicit-load registration persists.
  switch Auth_InMemory.lookupUser("x") {
  | Some(_) => ()
  | None => JsError.throwWithMessage("autoLoadOnce wiped explicit registration")
  }
})
