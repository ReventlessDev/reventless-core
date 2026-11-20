// The webhook door of an inbound translation slice: signature checks over the raw
// body, dispatch by path through the local registry, the caller a signed request
// acts as, and the audit row telling the two doors apart.

@@warning("-44")

open JestGlobals

let _ = TestRunner.setup()

module Webhook = ReventlessCore.InboundTranslationSlice_Webhook
module Callback = ReventlessCore.InboundTranslationSlice_Callback

let merchandiser = Reventless.Role.make("Merchandiser")

module FeedSpec = {
  let name = "SignedFeed"
  let moduleUrl = "signed-feed://spec"
  @schema type externalInput = {kind: string, id: string}
  @schema
  type command =
    | AddProduct({productId: @s.matches(Reventless.DcbTag.string) string})
    | AddCategory({categoryId: @s.matches(Reventless.DcbTag.string) string})
  let targetName = "AddProduct"
  let externalSystem = None
  type role = Reventless.Role.name
  let authorizationOf = (name: string): Reventless.Authorization.rule<role> =>
    switch name {
    | "AddProduct" => AllowRoles([merchandiser])
    | _ => AllowRoles([Reventless.Role.admin])
    }
  let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []
  let endpoint = Some({
    Reventless.InboundTranslationSlice.path: "/feeds/signed/",
    auth: SignedBody({
      header: "X-Signature",
      prefix: "sha256=",
      timestampHeader: "X-Timestamp",
      secret: "feed",
    }),
    role: merchandiser,
  })
}

let translateFeed = async (
  input: FeedSpec.externalInput,
  ~capabilities as _: Reventless.Capabilities.t,
  ~caller as _: option<Reventless.Identity.t>,
) =>
  switch input.kind {
  | "product" => Ok([(input.id, FeedSpec.AddProduct({productId: input.id}))])
  | "category" => Ok([(input.id, FeedSpec.AddCategory({categoryId: input.id}))])
  | kind => Error(`unknown kind ${kind}`)
  }

module FeedCallback = Callback.Make(
  FeedSpec,
  {
    let translate = translateFeed
    let moduleUrl = FeedSpec.moduleUrl
  },
)

module OpenSpec = {
  let name = "OpenFeed"
  let moduleUrl = "open-feed://spec"
  @schema type externalInput = {kind: string, id: string}
  @schema type command = AddProduct({productId: @s.matches(Reventless.DcbTag.string) string})
  let targetName = "AddProduct"
  let externalSystem = None
  type role = Reventless.Role.name
  let authorizationOf = (_: string): Reventless.Authorization.rule<role> => AllowAuthenticated
  let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []
  let endpoint = Some({Reventless.InboundTranslationSlice.path: "open", auth: Open})
}

module OpenCallback = Callback.Make(
  OpenSpec,
  {
    let translate = async (
      input: OpenSpec.externalInput,
      ~capabilities as _: Reventless.Capabilities.t,
      ~caller as _: option<Reventless.Identity.t>,
    ) => Ok([(input.id, OpenSpec.AddProduct({productId: input.id}))])
    let moduleUrl = OpenSpec.moduleUrl
  },
)

@schema type input = {id: string}

let published: ref<array<Reventless.Message.commandJson>> = ref([])
let publishJsons: ReventlessInfra.CommandTopic.publishJsons = async cmds =>
  published := published.contents->Array.concat(cmds)

let feedOps: ReventlessInfra.InboundTranslationSlice.operations = {
  receive: (input, ~caller=?, ~door=?) =>
    FeedCallback.receive(
      publishJsons,
      input,
      ~capabilities=Reventless.Capabilities.none,
      ~caller?,
      ~door?,
    ),
  refuse: async (~body, ~errorCode, error) => FeedCallback.refuse(~body, ~errorCode, error),
}
let openOps: ReventlessInfra.InboundTranslationSlice.operations = {
  receive: (input, ~caller=?, ~door=?) =>
    OpenCallback.receive(
      publishJsons,
      input,
      ~capabilities=Reventless.Capabilities.none,
      ~caller?,
      ~door?,
    ),
  refuse: async (~body, ~errorCode, error) => OpenCallback.refuse(~body, ~errorCode, error),
}

// The door an audit row records.
let viaWebhook: option<ReventlessInfra.InboundTranslationSlice.door> = Some(Webhook)
let viaMutation: option<ReventlessInfra.InboundTranslationSlice.door> = Some(Mutation)

let secret = "s3cret"
let now = 1_700_000_000.
let secretOf = name => name == "feed" ? Some(secret) : None

let signature: Reventless.InboundTranslationSlice.signature = {
  header: "X-Signature",
  prefix: "sha256=",
  timestampHeader: "X-Timestamp",
  secret: "feed",
}

let hmac = (~secret, text) =>
  NodeCrypto.createHmac("sha256", secret)->NodeCrypto.hmacUpdate(text)->NodeCrypto.hmacDigest("hex")

let signedHeaders = (~secret=secret, ~at=now, body) => {
  let at = at->Float.toString
  Dict.fromArray([
    ("x-timestamp", at),
    ("x-signature", "sha256=" ++ hmac(~secret, `${at}.${body}`)),
  ])
}

let body = (~kind="product", ~id="p-1") => `{"kind":"${kind}","id":"${id}"}`

let post = (~path="feeds/signed", ~method=?, ~headers=?, body) =>
  LocalWebhookRegistry.post(~path, ~method?, ~headers?, ~secretOf, ~nowSeconds=now, body)

let throws = (run: unit => unit): bool =>
  try {
    run()
    false
  } catch {
  | _ => true
  }

let rows = (log: dict<Callback.auditRow>) => log->Dict.valuesToArray

let clear = (log: dict<Callback.auditRow>) =>
  log->Dict.keysToArray->Array.forEach(key => log->Dict.delete(key))

describe("webhook signature", () => {
  let check = (~secrets=[secret], ~headers, text) =>
    Webhook.verify(signature, ~secrets, ~headers, ~body=text, ~nowSeconds=now)

  testSync("a signature by the shared secret passes", () =>
    expect(check(~headers=signedHeaders(body()), body()))->toEqual(Ok())
  )

  testSync("a signature by another secret is refused", () =>
    expect(check(~headers=signedHeaders(~secret="other", body()), body())->Result.isError)->toBe(
      true,
    )
  )

  testSync("a body changed after signing is refused", () =>
    expect(check(~headers=signedHeaders(body()), body(~id="p-2"))->Result.isError)->toBe(true)
  )

  testSync(
    "a timestamp outside the window is refused, so a captured request cannot be replayed",
    () =>
      expect(check(~headers=signedHeaders(~at=now -. 301., body()), body())->Result.isError)->toBe(
        true,
      ),
  )

  testSync("a request without the signature header is refused", () => {
    let headers = signedHeaders(body())
    headers->Dict.delete("x-signature")
    expect(check(~headers, body())->Result.isError)->toBe(true)
  })

  testSync("while a secret is rotated, either one passes", () =>
    expect(
      check(
        ~secrets=Webhook.secretsOf("new, old"),
        ~headers=signedHeaders(~secret="old", body()),
        body(),
      ),
    )->toEqual(Ok())
  )

  testSync("a secret is read from a variable named after it", () =>
    expect(Webhook.secretEnvKey("supplier-feed"))->toBe("REVENTLESS_WEBHOOK_SECRET_SUPPLIER_FEED")
  )
})

describe("webhook door", () => {
  beforeAll(() => {
    LocalWebhookRegistry.reset()
    switch (FeedCallback.webhook, OpenCallback.webhook) {
    | (Some(feed), Some(open_)) =>
      LocalWebhookRegistry.register(~route=feed, ~operations=Pulumi.Output.make(feedOps))
      LocalWebhookRegistry.register(~route=open_, ~operations=Pulumi.Output.make(openOps))
    | _ => JsError.throwWithMessage("fixture specs declare endpoints")
    }
  })
  afterAll(() => LocalWebhookRegistry.reset())
  beforeEach(() => {
    published := []
    clear(FeedCallback.auditLog)
    clear(OpenCallback.auditLog)
  })

  testPromise("a signed request publishes its commands as the endpoint's role", async () => {
    let response = await post(~headers=signedHeaders(body()), body())
    expect(response.status)->toBe(200)
    expect(published.contents->Array.map(c => c.id))->toEqual(["p-1"])
    expect(rows(FeedCallback.auditLog)->Array.map(row => row.door))->toEqual([viaWebhook])
  })

  testPromise("a command the endpoint's role may not send is refused", async () => {
    let text = body(~kind="category")
    let response = await post(~headers=signedHeaders(text), text)
    expect(response.status)->toBe(403)
    expect(published.contents)->toEqual([])
  })

  testPromise("a bad signature is refused before the body is read, with an audit row", async () => {
    let response = await post(~headers=signedHeaders(~secret="other", body()), body())
    expect(response.status)->toBe(401)
    expect(published.contents)->toEqual([])
    expect(
      rows(FeedCallback.auditLog)->Array.map(row => (row.status, row.door, row.input)),
    )->toEqual([(Callback.Failure, viaWebhook, body())])
  })

  testPromise("a signed body that is not JSON is refused", async () => {
    let response = await post(~headers=signedHeaders("not json"), "not json")
    expect(response.status)->toBe(400)
  })

  testPromise("an unknown path and a wrong method are refused", async () => {
    let unknown = await post(~path="nowhere", body())
    let wrongMethod = await post(~method="PUT", ~headers=signedHeaders(body()), body())
    expect((unknown.status, wrongMethod.status))->toEqual((404, 405))
  })

  testPromise("a secret the platform lacks fails closed, without an audit row", async () => {
    let response = await LocalWebhookRegistry.post(
      ~path="feeds/signed",
      ~headers=signedHeaders(body()),
      ~secretOf=_ => None,
      ~nowSeconds=now,
      body(),
    )
    expect(response.status)->toBe(500)
    expect(published.contents)->toEqual([])
    expect(rows(FeedCallback.auditLog))->toEqual([])
  })

  testPromise("an open URL identifies nobody, so a signed-in rule refuses it", async () => {
    let response = await post(~path="open", body())
    expect(response.status)->toBe(403)
  })

  testPromise("both doors publish the same commands and are told apart in the audit", async () => {
    let caller: Reventless.Identity.t = {
      userId: "u-1",
      username: "alice",
      groups: [(merchandiser :> string)],
      provider: InMemory,
    }
    let mutationResult = await feedOps.receive(JSON.parseOrThrow(body()), ~caller)
    let _ = await post(~headers=signedHeaders(body()), body())
    expect(mutationResult->Result.isOk)->toBe(true)
    switch published.contents->Array.map(c => c.commandJson) {
    | [viaMutationCommand, viaWebhookCommand] =>
      expect(viaWebhookCommand)->toEqual(viaMutationCommand)
    | commands => expect(commands->Array.length)->toBe(2)
    }
    expect(rows(FeedCallback.auditLog)->Array.map(row => row.door))->toEqual([
      viaMutation,
      viaWebhook,
    ])
  })

  testSync("two slices may not share a path", () =>
    switch FeedCallback.webhook {
    | Some(route) =>
      expect(
        throws(
          () => LocalWebhookRegistry.register(~route, ~operations=Pulumi.Output.make(feedOps)),
        ),
      )->toBe(true)
    | None => JsError.throwWithMessage("fixture spec declares an endpoint")
    }
  )
})

describe("which doors a slice has", () => {
  testSync("@noApi on externalInput withholds the mutation", () =>
    expect((
      Callback.exposesMutation(inputSchema->ReventlessInfra.Api.markNoApi->S.castToUnknown),
      Callback.exposesMutation(inputSchema->S.castToUnknown),
    ))->toEqual((false, true))
  )

  testSync("a slice with neither door is refused", () => {
    let check = (~webhook) =>
      throws(() => Callback.checkReachable(~plugin="P", ~slice="S", ~mutation=false, ~webhook))
    expect((check(~webhook=false), check(~webhook=true)))->toEqual((true, false))
  })
})

// ── The door over HTTP, and the secrets the local platform makes ──────────────

type httpOptions = {
  hostname: string,
  port: int,
  path: string,
  method: string,
  headers: dict<string>,
}
type httpReq
type httpRes
@module("node:http") external httpRequest: (httpOptions, httpRes => unit) => httpReq = "request"
@send external reqWrite: (httpReq, string) => unit = "write"
@send external reqEnd: (httpReq, @as(json`null`) _) => unit = "end"
@send external resOnData: (httpRes, @as("data") _, string => unit) => unit = "on"
@send external resOnEnd: (httpRes, @as("end") _, unit => unit) => unit = "on"
@send external resSetEncoding: (httpRes, string) => unit = "setEncoding"
@get external resStatus: httpRes => int = "statusCode"

// High ephemeral port, clear of dev-server defaults and the other HTTP tests.
let httpPort = 49341

let httpPost = (path, ~headers, body): promise<(int, string)> =>
  Promise.make((resolve, _) => {
    let req = httpRequest(
      {
        hostname: "localhost",
        port: httpPort,
        path,
        method: "POST",
        headers: headers
        ->Dict.toArray
        ->Array.concat([("content-type", "application/json")])
        ->Dict.fromArray,
      },
      res => {
        res->resSetEncoding("utf8")
        let text = ref("")
        res->resOnData(chunk => text := text.contents ++ chunk)
        res->resOnEnd(() => resolve((res->resStatus, text.contents)))
      },
    )
    req->reqWrite(body)
    req->reqEnd
  })

let feedVariable = Webhook.secretEnvKey("feed")

let secretsFile = (dir): LocalWebhookSecrets.file =>
  NodePath.join([dir, LocalWebhookSecrets.fileName])
  ->NodeFs.readFileSync
  ->JSON.parseOrThrow
  ->Reventless.Util_Sury.fromJson(LocalWebhookSecrets.fileSchema)

describe("webhook door over HTTP", () => {
  let dir = NodePath.join([
    NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "webhook-secrets-"])),
    ".reventless",
  ])

  beforeAllAsync(async () => {
    NodeProcess.env->Dict.delete(feedVariable)
    NodeFs.mkdirSync(dir, {recursive: true})
    LocalWebhookRegistry.reset()
    switch (FeedCallback.webhook, OpenCallback.webhook) {
    | (Some(feed), Some(open_)) =>
      LocalWebhookRegistry.register(~route=feed, ~operations=Pulumi.Output.make(feedOps))
      LocalWebhookRegistry.register(~route=open_, ~operations=Pulumi.Output.make(openOps))
    | _ => JsError.throwWithMessage("fixture specs declare endpoints")
    }
    DomainGraphQL_Server.reset()
    DomainGraphQL_Server.registerTypes(~sdlTypes=ReventlessCore.GraphQL_Stitcher.relayBaseTypes)
    DomainGraphQL_Server.registerQueries(
      ~sdlFields=ReventlessCore.GraphQL_Stitcher.relayBaseQueries,
      ~resolvers=Dict.make(),
    )
    DomainGraphQL_Server.start(~port=httpPort, ())
    await Promise.make((resolve, _) => setTimeout(() => resolve(), 50)->ignore)
  })
  afterAll(() => {
    DomainGraphQL_Server.stop()
    LocalWebhookRegistry.reset()
    NodeProcess.env->Dict.delete(feedVariable)
  })
  beforeEach(() => published := [])

  testSync("each signed door gets a secret, kept with the doors a caller posts to", () => {
    let written = LocalWebhookSecrets.ensureIn(~dir)
    let file = secretsFile(dir)
    let kept = file.secrets->Dict.get("feed")
    // Started again, the platform keeps the secret a caller already signs with.
    NodeProcess.env->Dict.delete(feedVariable)
    LocalWebhookSecrets.ensureIn(~dir)->ignore
    expect((
      written->Option.isSome,
      kept->Option.map(String.length),
      NodeProcess.env->Dict.get(feedVariable) == kept,
      secretsFile(dir).secrets->Dict.get("feed") == kept,
      file.doors->Array.map(d => (d.path, d.secret, d.header)),
    ))->toEqual((
      true,
      Some(64),
      true,
      true,
      [("feeds/signed", Some("feed"), Some("X-Signature")), ("open", None, None)],
    ))
  })

  testPromise("a post signed with that secret reaches the translation over HTTP", async () => {
    LocalWebhookSecrets.ensureIn(~dir)->ignore
    let secret = secretsFile(dir).secrets->Dict.get("feed")->Option.getOr("")
    let text = body()
    let (status, _) = await httpPost(
      "/webhooks/feeds/signed",
      ~headers=signedHeaders(~secret, ~at=Date.now() /. 1000., text),
      text,
    )
    let (refused, _) = await httpPost(
      "/webhooks/feeds/signed",
      ~headers=signedHeaders(~secret="other", ~at=Date.now() /. 1000., text),
      text,
    )
    let (nowhere, _) = await httpPost("/webhooks/no/such/door", ~headers=Dict.make(), text)
    expect((status, published.contents->Array.map(c => c.id), refused == 200, nowhere))->toEqual((
      200,
      ["p-1"],
      false,
      404,
    ))
  })

  testSync("a secret pinned in its variable is left as it is", () => {
    NodeProcess.env->Dict.set(feedVariable, "pinned")
    LocalWebhookSecrets.ensureIn(~dir)->ignore
    expect((
      NodeProcess.env->Dict.get(feedVariable),
      secretsFile(dir).secrets->Dict.get("feed"),
    ))->toEqual((Some("pinned"), Some("pinned")))
  })
})
