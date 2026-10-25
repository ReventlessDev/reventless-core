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
