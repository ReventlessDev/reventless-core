// E2E verification for client-publishable Events channels (`/client/**`).
//
//   pnpm run verify:client-publish        # pick a stack (or set SEED_STACK), then log in
//
// The design this checks rests on one AWS behaviour that cannot be verified
// locally: a channel namespace's `publishAuthModes` overriding the API-level
// `defaultPublishAuthModes`. That override is what lets an authenticated
// browser publish presence/chat on `/client/**` while read-model change
// descriptors on `/default/**` stay publishable only by the SigV4-signed
// Lambdas — i.e. unforgeable. The local Events transport cannot corroborate it
// (both ends of that emulator live in this repo), so this script is the check.
//
// Four assertions, in order of what they'd cost to get wrong:
//
//   1. the deployment advertises `clientEventsNamespace` in config.json
//      (without it every client-channel surface stays dark by design);
//   2. a Cognito IdToken can subscribe to a `/client/**` channel;
//   3. a Cognito publish to `/client/**` returns 2xx AND the event actually
//      arrives on that subscription — delivery, not just acceptance;
//   4. the SAME token publishing to `/default/**` is REJECTED.
//
// (4) is the one that matters most. If it ever passes, a browser can forge a
// read-model change descriptor and the namespace split is isolating nothing —
// so this script treats that as a failure regardless of how (1)–(3) went.
//
// Companion to `verify-subscriptions.mjs`, which covers the Lambda→browser
// direction with SigV4. This one is the browser→browser direction with Cognito,
// and needs no AWS credentials at all — only a pool user.
//
// Plan: reventless-core docs/plans/events-client-publish-channels.md (Phase 6).

open ReventlessSeed

// `fetch`, `WebSocket`, timers and base64 all come from `rescript-web` — the
// same bindings the browser client uses, which is the point: this script
// exercises the deployed API over exactly the surface the UI does, rather than
// over a second hand-rolled approximation of it.
open Web

@scope("process") @val external exit: int => unit = "exit"

// ── Small helpers ───────────────────────────────────────────────────────────

let field = (json: JSON.t, key: string): option<JSON.t> =>
  json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(key))

let asString = (json: JSON.t): option<string> => json->JSON.Decode.string

let delay = Timers.delay

// Distinguishes one run's channel and marker from any other, so a stale
// subscriber or a replayed frame cannot fake a pass.
let randomSuffix = (): string => {
  let s = Math.random()->Float.toString
  s->String.slice(~start=2, ~end=String.length(s))
}

// ── Result accounting ───────────────────────────────────────────────────────

type check = {label: string, passed: bool, detail: string}

let checks: ref<array<check>> = ref([])

let record = (~label: string, ~passed: bool, ~detail: string): unit => {
  checks.contents->Array.push({label, passed, detail})
  Console.log(`${passed ? "  PASS" : "  FAIL"}  ${label}\n        ${detail}`)
}

// ── Channel/URL derivation (mirrors the browser client) ─────────────────────

// Same transform EventsClient.toRealtimeUrl applies: the realtime host differs
// from the HTTPS one, and the subprotocol blob carries the *HTTPS* host.
let toRealtimeUrl = (endpoint: string): string => {
  let withWss = if endpoint->String.startsWith("https://") {
    "wss://" ++ endpoint->String.slice(~start=8, ~end=String.length(endpoint))
  } else {
    endpoint
  }
  let swapped = withWss->String.replace("appsync-api.", "appsync-realtime-api.")
  swapped->String.endsWith("/realtime") ? swapped : swapped ++ "/realtime"
}

let apiHost = (endpoint: string): string => {
  let noScheme = endpoint->String.startsWith("https://")
    ? endpoint->String.slice(~start=8, ~end=String.length(endpoint))
    : endpoint
  switch noScheme->String.indexOf("/") {
  | -1 => noScheme
  | i => noScheme->String.slice(~start=0, ~end=i)
  }
}

let authSubprotocol = (~host: string, ~idToken: string): string =>
  "header-" ++
  Base64.btoaUrl(
    Dict.fromArray([
      ("host", JSON.Encode.string(host)),
      ("Authorization", JSON.Encode.string(idToken)),
    ])
    ->JSON.Encode.object
    ->JSON.stringify,
  )

// ── Publish ─────────────────────────────────────────────────────────────────

/** POST one event as the browser does: the IdToken in `Authorization`, no
    SigV4. Returns (status, body) so the caller can assert on either. */
let publish = async (
  ~endpoint: string,
  ~idToken: string,
  ~channel: string,
  ~payload: JSON.t,
): (int, string) => {
  let body =
    Dict.fromArray([
      ("channel", JSON.Encode.string(channel)),
      ("events", [JSON.Encode.string(payload->JSON.stringify)]->JSON.Encode.array),
    ])
    ->JSON.Encode.object
    ->JSON.stringify
  let res = await Fetch.fetch(
    `${endpoint}/event`,
    {
      method: "POST",
      headers: Dict.fromArray([
        ("Content-Type", "application/json"),
        ("Authorization", idToken),
      ]),
      body: Fetch.Body.string(body),
    },
  )
  let text = await res->Fetch.text
  (res->Fetch.status, text)
}

// ── Subscribe ───────────────────────────────────────────────────────────────

type socket = {
  ws: Socket.t,
  /** Events received on the subscription, newest last. */
  received: ref<array<JSON.t>>,
  acked: ref<bool>,
  subscribed: ref<bool>,
  failure: ref<option<string>>,
}

/** Open the realtime socket, connection_init → ack, then subscribe. Resolves
    once subscribe_success arrives (or the deadline passes). */
let openSubscription = async (
  ~endpoint: string,
  ~idToken: string,
  ~channel: string,
): socket => {
  let host = apiHost(endpoint)
  let ws = Socket.make(
    toRealtimeUrl(endpoint),
    ["aws-appsync-event-ws", authSubprotocol(~host, ~idToken)],
  )
  let sock = {
    ws,
    received: ref([]),
    acked: ref(false),
    subscribed: ref(false),
    failure: ref(None),
  }
  let subId = "verify-1"
  ws->Socket.setOnError(_ => sock.failure := Some("WebSocket error (connection rejected?)"))
  ws->Socket.setOnOpen(() => ws->Socket.send(`{"type":"connection_init"}`))
  ws->Socket.setOnMessage(evt => {
    switch evt.data->JSON.parseOrThrow->field("type")->Option.flatMap(asString) {
    | Some("connection_ack") =>
      sock.acked := true
      ws->Socket.send(
        Dict.fromArray([
          ("type", JSON.Encode.string("subscribe")),
          ("id", JSON.Encode.string(subId)),
          ("channel", JSON.Encode.string(channel)),
          (
            "authorization",
            Dict.fromArray([
              ("host", JSON.Encode.string(host)),
              ("Authorization", JSON.Encode.string(idToken)),
            ])->JSON.Encode.object,
          ),
        ])
        ->JSON.Encode.object
        ->JSON.stringify,
      )
    | Some("subscribe_success") => sock.subscribed := true
    | Some("subscribe_error") | Some("connection_error") =>
      sock.failure := Some(evt.data)
    | Some("data") =>
      // `event` is a stringified JSON payload, as AWS delivers it.
      switch evt.data->JSON.parseOrThrow->field("event")->Option.flatMap(asString) {
      | Some(raw) =>
        switch try Some(raw->JSON.parseOrThrow) catch {
        | _ => None
        } {
        | Some(parsed) => sock.received.contents->Array.push(parsed)
        | None => ()
        }
      | None => ()
      }
    | _ => ()
    }
  })
  // Poll for the handshake rather than racing a fixed sleep.
  let deadline = 40
  let rec wait = async (n: int) =>
    if sock.subscribed.contents || sock.failure.contents->Option.isSome || n == 0 {
      ()
    } else {
      await delay(250)
      await wait(n - 1)
    }
  await wait(deadline)
  sock
}

// ── The run ─────────────────────────────────────────────────────────────────

let run = async () => {
  Console.log("\nVerifying client-publishable Events channels\n")

  // Stack + config discovery reuses the seed tooling, so this script stays in
  // step with however `pnpm run seed` resolves a deployment.
  let backend = switch Seed.Prompt.envValue("SEED_PULUMI_BACKEND") {
  | Some(url) => Some(url)
  | None => Some("https://api.pulumi.com")
  }
  let stack = await ReventlessSeedAws.resolveStack(
    ~projectDir=".",
    ~backend,
    ~stack=Seed.Prompt.envValue("SEED_STACK"),
  )
  let outputs = ReventlessSeedAws.stackOutputs(~projectDir=".", ~backend, stack)
  let hostShellUrl = switch outputs
  ->field("hostShellUrl")
  ->Option.flatMap(asString) {
  | Some(u) => u
  | None =>
    throw(
      Seed.Failed(
        `stack "${stack}" exports no hostShellUrl — this check reads the deployed config.json`,
      ),
    )
  }
  let cfg = await ReventlessSeedAws.fetchConfig(hostShellUrl)
  let fromCfg = key => cfg->field(key)->Option.flatMap(asString)

  Console.log(`Stack:        ${stack}`)
  Console.log(`Host shell:   ${hostShellUrl}\n`)

  // ── 1. capability advertisement ──
  let namespace = fromCfg("clientEventsNamespace")
  record(
    ~label="config.json advertises clientEventsNamespace",
    ~passed=namespace->Option.isSome,
    ~detail=switch namespace {
    | Some(ns) => `clientEventsNamespace = "${ns}"`
    | None => "absent — every client-channel surface stays dark; is reventless-aws current on this stack?"
    },
  )

  let eventsEndpoint = switch fromCfg("domainApiEventsEndpoint") {
  | Some(e) => e
  | None => throw(Seed.Failed("config.json carries no domainApiEventsEndpoint"))
  }
  let region = fromCfg("region")->Option.getOr("<unset>")
  let clientId = switch fromCfg("cognitoClientId") {
  | Some(c) => c
  | None => throw(Seed.Failed("config.json carries no cognitoClientId"))
  }
  Console.log(`\nEvents API:   ${eventsEndpoint}`)
  Console.log(`Log in to ${region} pool client ${clientId}\n`)

  let (username, password) = await Seed.Prompt.credentials()
  let idToken = await ReventlessSeedAws.cognito(~region, ~clientId)(~username, ~password)
  Console.log("\nGot an IdToken. Running assertions:\n")

  let ns = namespace->Option.getOr("client")
  // Unique per run so a stale subscriber elsewhere cannot fake a pass.
  let runId = `verify-${randomSuffix()}`
  let clientChannel = `/${ns}/verify/${runId}`

  // ── 2. subscribe with a Cognito token ──
  let sock = await openSubscription(~endpoint=eventsEndpoint, ~idToken, ~channel=clientChannel)
  record(
    ~label="Cognito IdToken can subscribe to a client channel",
    ~passed=sock.subscribed.contents,
    ~detail=switch (sock.subscribed.contents, sock.acked.contents, sock.failure.contents) {
    | (true, _, _) => `subscribed to ${clientChannel}`
    | (false, _, Some(err)) => `failed: ${err}`
    | (false, false, None) => "no connection_ack — the socket never completed its handshake"
    | (false, true, None) => "acked but never subscribed (timed out)"
    },
  )

  // ── 3. publish to /client/** and confirm delivery ──
  let marker = `marker-${runId}`
  let (clientStatus, clientBody) = await publish(
    ~endpoint=eventsEndpoint,
    ~idToken,
    ~channel=clientChannel,
    ~payload=Dict.fromArray([("marker", JSON.Encode.string(marker))])->JSON.Encode.object,
  )
  let accepted = clientStatus >= 200 && clientStatus < 300
  record(
    ~label="Cognito publish to a client channel is ACCEPTED",
    ~passed=accepted,
    ~detail=accepted
      ? `HTTP ${clientStatus->Int.toString} — the per-namespace publishAuthModes override works`
      : `HTTP ${clientStatus->Int.toString}: ${clientBody}\n        ` ++
        "→ the namespace override did NOT take effect; the fallback is an onPublish handler or a separate API",
  )

  // Acceptance is not delivery — wait for the frame to come back round.
  let rec awaitMarker = async (n: int) =>
    if n == 0 {
      false
    } else if sock.received.contents->Array.some(e =>
      e->field("marker")->Option.flatMap(asString) == Some(marker)
    ) {
      true
    } else {
      await delay(250)
      await awaitMarker(n - 1)
    }
  let delivered = await awaitMarker(40)
  record(
    ~label="the published event is DELIVERED to the subscriber",
    ~passed=delivered,
    ~detail=delivered
      ? "round trip completed — browser→platform→browser fan-out works"
      : `no frame carrying ${marker} arrived within 10s (${sock.received.contents
        ->Array.length
        ->Int.toString} other events seen)`,
  )

  // ── 4. the security assertion ──
  let defaultChannel = "/default/verify/should-be-rejected"
  let (defaultStatus, defaultBody) = await publish(
    ~endpoint=eventsEndpoint,
    ~idToken,
    ~channel=defaultChannel,
    ~payload=Dict.fromArray([
      ("changeKind", JSON.Encode.string("Removed")),
      ("id", JSON.Encode.string("forged-by-verify-script")),
    ])->JSON.Encode.object,
  )
  let rejected = defaultStatus >= 400
  record(
    ~label="Cognito publish to /default/** is REJECTED",
    ~passed=rejected,
    ~detail=rejected
      ? `HTTP ${defaultStatus->Int.toString} — change descriptors stay unforgeable`
      : `HTTP ${defaultStatus->Int.toString}: ${defaultBody}\n        ` ++
        "→ SERIOUS: a browser can forge a read-model change descriptor. " ++
        "The namespace split is isolating nothing — do not ship this.",
  )

  sock.ws->Socket.close
  Seed.Prompt.close()

  let failed = checks.contents->Array.filter(c => !c.passed)
  let total = checks.contents->Array.length->Int.toString
  Console.log("")
  if failed->Array.length == 0 {
    Console.log(`All ${total} checks passed.\n`)
    exit(0)
  } else {
    Console.log(
      `${failed->Array.length->Int.toString} of ${total} checks FAILED:\n` ++
      failed->Array.map(c => `  - ${c.label}`)->Array.join("\n") ++
      "\n",
    )
    exit(1)
  }
}

let _ = run()->Promise.catch(err => {
  Seed.Prompt.close()
  switch err {
  | Seed.Failed(msg) => Console.error(`\n${msg}\n`)
  | e => Console.error2("\nverification failed:", e)
  }
  exit(1)
  Promise.resolve()
})
