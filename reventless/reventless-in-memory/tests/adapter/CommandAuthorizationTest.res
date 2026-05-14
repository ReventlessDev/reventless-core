// Resolver-boundary tests for per-constructor authorization (A3.3 + A3.3b).
// Mirrors the catalog Category aggregate's command shape: a record-payload
// constructor `Add({name})` defaulting to AllowAuthenticated, plus a
// payload-less `Archive` constrained to AllowGroups(["Admin"]).
//
// The PPX emits a `commandAuthorization` switch at compile time (see
// examples/online-shop-hybrid/catalog/.../Category.res.mjs). This test hand-
// writes an equivalent switch and feeds it through the live resolver path
// (CommandGeneratorResolvers_GraphQL.register), so the test covers the same
// runtime call shape that PPX-generated code produces.

@@warning("-44")

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect

let _ = TestRunner.setup()

// ── Synthetic command schema mirroring Category ──────────────────────────────

@schema
type command =
  | Add({name: string})
  | Rename({name: string})
  | Archive

// Matches the shape the PPX emits for `@authorize(AllowGroups(["Admin"]))` on
// the payload-less `Archive` constructor with a file-level default.
let commandAuthorization = (cmd: unknown): Reventless.Authorization.permission =>
  if (cmd->Obj.magic: 'a) === "Archive" {
    AllowGroups(["Admin"])
  } else {
    AllowAuthenticated
  }

// ── Identity fixtures ────────────────────────────────────────────────────────

let adminIdentity: Reventless.Identity.t = {
  userId: "u-admin",
  username: "admin",
  groups: ["Admin", "User"],
  provider: InMemory,
}

let userIdentity: Reventless.Identity.t = {
  userId: "u-user",
  username: "user",
  groups: ["User"],
  provider: InMemory,
}

let ctxFor = (identity: Reventless.Identity.t): JSON.t =>
  JSON.Encode.object(
    Dict.fromArray([("identity", (identity: Reventless.Identity.t)->Obj.magic)]),
  )

let anonymousCtx: JSON.t =
  JSON.Encode.object(
    Dict.fromArray([("identity", (Reventless.Identity.anonymous: Reventless.Identity.t)->Obj.magic)]),
  )

let getTypename = (response: JSON.t): string =>
  response
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get("__typename"))
  ->Option.flatMap(JSON.Decode.string)
  ->Option.getOr("")

let getErrorCode = (response: JSON.t): string =>
  response
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get("errorCode"))
  ->Option.flatMap(JSON.Decode.string)
  ->Option.getOr("")

// ── Per-test fixture — fresh server + handler + resolvers ────────────────────

let buildFixture = (~namespace: string) => {
  // Use the domain server (a singleton) and reset it before each test so
  // mutation registrations don't leak across cases.
  let server = DomainGraphQL_Server.asInterface
  let calls: ref<array<string>> = ref([])

  let addField = `${namespace}_Add`
  let renameField = `${namespace}_Rename`
  let archiveField = `${namespace}_Archive`

  CommandGeneratorResolvers_GraphQL.register(
    ~fields=[addField, renameField, archiveField],
    ~commandSchema=commandSchema->S.castToUnknown,
    ~commandAuthorization,
    ~server,
  )

  // Stub generateCommand: record the command name + return Accepted.
  let stubGenerateCommand: ReventlessCore.CommandGenerator.commandGenerator = payload =>
    Effect.promise(() => {
      calls.contents->Array.push(payload.command)
      Promise.resolve(
        ReventlessCore.CommandTopic.Accepted({
          msgId: "msg-" ++ payload.command,
          eventCount: 1,
        }),
      )
    })

  [addField, renameField, archiveField]->Array.forEach(field =>
    CommandGeneratorResolvers_GraphQL.bindHandler(~field, ~generateCommand=stubGenerateCommand)
  )

  let resolverFor = field =>
    switch server.getMutationResolver(field) {
    | Some(r) => r
    | None => JsError.throwWithMessage("resolver not registered: " ++ field)
    }

  (resolverFor(addField), resolverFor(renameField), resolverFor(archiveField), calls)
}

// ── Tests ────────────────────────────────────────────────────────────────────

describe("CommandGeneratorResolvers_GraphQL — per-constructor authorization", () => {
  beforeEach(() => {
    DomainGraphQL_Server.asInterface.reset()
  })

  testPromise("admin invoking payload-less Archive succeeds", async () => {
    let (_, _, archiveResolver, calls) = buildFixture(~namespace="Cat1")
    let response =
      await archiveResolver(JSON.Encode.null, JSON.Encode.object(Dict.make()), ctxFor(adminIdentity))
    expect(getTypename(response))->toEqual("CommandAccepted")
    expect(calls.contents)->toEqual(["Archive"])
  })

  testPromise("regular user invoking Archive is rejected with Forbidden", async () => {
    let (_, _, archiveResolver, calls) = buildFixture(~namespace="Cat2")
    let response =
      await archiveResolver(JSON.Encode.null, JSON.Encode.object(Dict.make()), ctxFor(userIdentity))
    expect(getTypename(response))->toEqual("CommandRejected")
    expect(getErrorCode(response))->toEqual("Forbidden")
    expect(calls.contents)->toEqual([])
  })

  testPromise("anonymous invoking Archive is rejected with Forbidden", async () => {
    let (_, _, archiveResolver, calls) = buildFixture(~namespace="Cat3")
    let response =
      await archiveResolver(JSON.Encode.null, JSON.Encode.object(Dict.make()), anonymousCtx)
    expect(getTypename(response))->toEqual("CommandRejected")
    expect(getErrorCode(response))->toEqual("Forbidden")
    expect(calls.contents)->toEqual([])
  })

  testPromise("regular user invoking Add (default AllowAuthenticated) succeeds", async () => {
    let (addResolver, _, _, calls) = buildFixture(~namespace="Cat4")
    let response =
      await addResolver(
        JSON.Encode.null,
        JSON.Encode.object(Dict.fromArray([("name", JSON.Encode.string("Books"))])),
        ctxFor(userIdentity),
      )
    expect(getTypename(response))->toEqual("CommandAccepted")
    expect(calls.contents)->toEqual(["Add"])
  })

  testPromise("anonymous invoking Add is rejected (AllowAuthenticated default)", async () => {
    let (addResolver, _, _, calls) = buildFixture(~namespace="Cat5")
    let response =
      await addResolver(
        JSON.Encode.null,
        JSON.Encode.object(Dict.fromArray([("name", JSON.Encode.string("Books"))])),
        anonymousCtx,
      )
    expect(getTypename(response))->toEqual("CommandRejected")
    expect(getErrorCode(response))->toEqual("Forbidden")
    expect(calls.contents)->toEqual([])
  })

  testPromise("admin invoking Add also succeeds (admin has User group too)", async () => {
    let (addResolver, _, _, calls) = buildFixture(~namespace="Cat6")
    let response =
      await addResolver(
        JSON.Encode.null,
        JSON.Encode.object(Dict.fromArray([("name", JSON.Encode.string("Books"))])),
        ctxFor(adminIdentity),
      )
    expect(getTypename(response))->toEqual("CommandAccepted")
    expect(calls.contents)->toEqual(["Add"])
  })

  testPromise(
    "payload-less Archive registered as a GraphQL mutation field (no longer filtered)",
    async () => {
      let (_, _, _, _) = buildFixture(~namespace="Cat7")
      let sdl = DomainGraphQL_Server.asInterface.buildSdl()
      // Three mutation fields should now be present, including Archive.
      expect(sdl->String.includes("Cat7_Add"))->toEqual(true)
      expect(sdl->String.includes("Cat7_Rename"))->toEqual(true)
      expect(sdl->String.includes("Cat7_Archive"))->toEqual(true)
    },
  )
})
