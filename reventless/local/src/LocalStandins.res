// The stand-ins a local platform runs beside its plugins: started once the servers
// listen, unless `REVENTLESS_STANDINS=off`, and the platform's devices provider
// while they run. They stay a client of the platform: they read views through
// GraphQL and send through the inbound translations' doors, in this process only
// for convenience. Served at `/__inmemory/standins` and as domain MCP tools.

module Standin = ReventlessStandin.Standin
module Seed = ReventlessSeed.Seed

/** What an app hands its local platform: its stand-ins' kinds, and how fast and
    with which seed they play. `REVENTLESS_STANDINS_SPEED` and
    `REVENTLESS_STANDINS_SEED` override both. */
type config = {kinds: array<Standin.Kind.t>, speed?: float, seed?: int}

/** What the app handed over, started by `Platform.startServers`. */
let handed: ref<option<config>> = ref(None)

/** Hands the app's stand-ins to the local platform; call it before `Platform.startServers()`. */
let use = (config: config): unit => handed := Some(config)

let envVar = "REVENTLESS_STANDINS"

let isOff = (~env=NodeProcess.env): bool =>
  env->Dict.get(envVar)->Option.map(String.toLowerCase) == Some("off")

let running: ref<option<Standin.Runtime.t>> = ref(None)

/** The account the stand-ins read views as: their own, in no group. */
let identity: Reventless.Identity.t = {
  userId: "local-standins",
  username: "standins",
  groups: [],
  provider: InMemory,
}

let log = ReventlessCore.Logger.fromEnv()
let info = message => log.info(~comp="Standins", message)
let error = message => log.error(~comp="Standins", message)

/** The doors as this process holds them: each registered route, signed with the
    secret its variable holds, so nothing is read from a file. */
let doors = (~base: string): array<Standin.Doors.door> =>
  LocalWebhookRegistry.doors()->Array.filterMap(r => {
    let url = `${base}/${r.path}`
    switch r.auth {
    | Open => Some({Standin.Doors.slice: r.slice, url, method: r.method})
    | SignedBody({secret, header, ?prefix, ?timestampHeader}) =>
      ReventlessCore.InboundTranslationSlice_Webhook.secretFromEnv(secret)
      ->Option.flatMap(raw => ReventlessCore.InboundTranslationSlice_Webhook.secretsOf(raw)[0])
      ->Option.map(value => {
        Standin.Doors.slice: r.slice,
        url,
        method: r.method,
        signing: {header, ?prefix, ?timestampHeader, secret: value},
      })
    }
  })

let devicesOf = (runtime: Standin.Runtime.t): Reventless.Devices.t => {
  tell: async (~kind, ~instance, ~message, ~body) =>
    switch await runtime->Standin.Runtime.tell(~kind, ~instance, ~message, ~body) {
    | Accepted => Accepted
    | Refused(why) => Refused(why)
    | NotReachable(why) => NotReachable(why)
    },
}

let speedFrom = (config: config, ~env) =>
  switch env->Dict.get("REVENTLESS_STANDINS_SPEED")->Option.map(Seed.Pace.parseSpeed) {
  | Some(Ok(speed)) => speed
  | Some(Error(why)) =>
    error(`REVENTLESS_STANDINS_SPEED: ${why}; playing at real time`)
    1.
  | None => config.speed->Option.getOr(1.)
  }

/** Starts the stand-ins against the platform on `domainPort`. A failure is logged, never thrown:
    a platform whose stand-ins could not start still serves its plugins. */
let start = async (config: config, ~domainPort: int, ~env=NodeProcess.env): unit =>
  if config.kinds == [] {
    ()
  } else if isOff(~env) {
    info(
      `off (${envVar}=off): no thing sends by itself, and every thing told something is not reachable`,
    )
  } else {
    let base = `http://localhost:${domainPort->Int.toString}`
    let client = Seed.Client.make(~config={endpoint: `${base}/graphql`})
    client->Seed.Client.useToken(LocalAuth.Login.mint(identity))
    switch await Seed.Commands.fetch(client) {
    | exception _ => error("the API's description could not be read; the stand-ins do not run")
    | commands =>
      let runtime = Standin.Runtime.make(
        ~client,
        ~doors=doors(~base=`${base}/webhooks`),
        ~commands,
        ~kinds=config.kinds,
        ~speed=speedFrom(config, ~env),
        ~seed=env
        ->Dict.get("REVENTLESS_STANDINS_SEED")
        ->Option.flatMap(s => Int.fromString(s))
        ->Option.getOr(config.seed->Option.getOr(1)),
        (),
      )
      LocalCapabilities.registerDevices(devicesOf(runtime))
      await runtime->Standin.Runtime.start
      // A thing added to its view gets a twin at once, not at the next interval.
      let pending = ref(false)
      LocalEventTap.listen(_ =>
        if !pending.contents {
          pending := true
          let _ = NodeTimers.setTimeout(() => {
            pending := false
            runtime->Standin.Runtime.refresh->ignore
          }, 100)
        }
      )
      running := Some(runtime)
      info(
        `${config.kinds
          ->Array.map(k => k.name)
          ->Array.join(
            ", ",
          )} at ${runtime.speed->Float.toString}x, served at ${base}/__inmemory/standins`,
      )
    }
  }

// ── Served ──────────────────────────────────────────────────────────────────

let str = JSON.Encode.string

let ratesJson = (r: Standin.Kind.rates): JSON.t =>
  JSON.Encode.object(
    Dict.fromArray([
      ("silence", JSON.Encode.float(r.silence)),
      ("repeats", JSON.Encode.float(r.repeats)),
      ("late", JSON.Encode.float(r.late)),
      ("drift", JSON.Encode.float(r.drift)),
    ]),
  )

let sentJson = (s: Standin.Runtime.sent): JSON.t =>
  JSON.Encode.object(
    Dict.fromArray([
      ("kind", str(s.kind)),
      ("id", str(s.id)),
      ("slice", str(s.slice)),
      ("status", JSON.Encode.int(s.status)),
      ("at", str(s.at)),
      ("body", s.body),
    ]),
  )

/** Every kind with its twins and their state, its rates and whether it runs; the last sends. */
let stateJson = (r: Standin.Runtime.t): JSON.t =>
  JSON.Encode.object(
    Dict.fromArray([
      ("speed", JSON.Encode.float(r.speed)),
      (
        "kinds",
        r.kinds
        ->Array.map(k =>
          JSON.Encode.object(
            Dict.fromArray([
              ("name", str(k.name)),
              ("on", JSON.Encode.bool(r->Standin.Runtime.isOn(~kind=k.name))),
              ("byHandOnly", JSON.Encode.bool(k.timers == [])),
              ("messages", k.messages->Array.map(str)->JSON.Encode.array),
              ("rates", ratesJson(k.rates())),
              (
                "instances",
                k.twins()
                ->Array.map(((id, twin)) =>
                  switch twin {
                  | Object(d) =>
                    JSON.Encode.object(Dict.fromArray([("id", str(id))])->Dict.assign(d))
                  | other => other
                  }
                )
                ->JSON.Encode.array,
              ),
            ]),
          )
        )
        ->JSON.Encode.array,
      ),
      ("recent", r->Standin.Runtime.recent->Array.map(sentJson)->JSON.Encode.array),
    ]),
  )

let errorJson = message => JSON.Encode.object(Dict.fromArray([("error", str(message))]))

let field = (d: dict<JSON.t>, k) => d->Dict.get(k)->Option.flatMap(JSON.Decode.string)
let number = (d: dict<JSON.t>, k) => d->Dict.get(k)->Option.flatMap(JSON.Decode.float)

/** Sends one message for one twin by hand: what each door answered. */
let sendByHand = async (r: Standin.Runtime.t, d: dict<JSON.t>): (int, JSON.t) =>
  switch (field(d, "kind"), field(d, "id"), field(d, "message")) {
  | (Some(kind), Some(id), Some(message)) =>
    let fields =
      d->Dict.get("fields")->Option.flatMap(JSON.Decode.object)->Option.getOr(Dict.make())
    switch await r->Standin.Runtime.byHand(~kind, ~id, ~message, ~fields) {
    | Error(why) => (400, errorJson(why))
    | Ok(answers) => (
        200,
        JSON.Encode.object(
          Dict.fromArray([("sent", answers->Array.map(sentJson)->JSON.Encode.array)]),
        ),
      )
    }
  | _ => (400, errorJson("give kind, id and message"))
  }

let switchKind = (r: Standin.Runtime.t, d: dict<JSON.t>): (int, JSON.t) =>
  switch (field(d, "kind"), d->Dict.get("on")->Option.flatMap(JSON.Decode.bool)) {
  | (Some(kind), Some(on)) =>
    switch r->Standin.Runtime.switchKind(~kind, ~on) {
    | Ok() => (200, stateJson(r))
    | Error(why) => (404, errorJson(why))
    }
  | _ => (400, errorJson("give kind and on"))
  }

/** Changes a kind's misbehaviour (any of its four rates), and with `silenceInstance` and
    `ticks` silences that twin on purpose. */
let misbehave = (r: Standin.Runtime.t, d: dict<JSON.t>): (int, JSON.t) =>
  switch field(d, "kind") {
  | None => (400, errorJson("give kind"))
  | Some(kind) =>
    switch r.kinds->Array.find(k => k.name == kind) {
    | None => (404, errorJson(`no kind ${kind}`))
    | Some(k) =>
      let now = k.rates()
      let rate = (name, current) =>
        switch number(d, name) {
        | Some(p) if p >= 0. && p <= 1. => p
        | _ => current
        }
      let rates: Standin.Kind.rates = {
        silence: rate("silence", now.silence),
        repeats: rate("repeats", now.repeats),
        late: rate("late", now.late),
        drift: rate("drift", now.drift),
      }
      let silenced = switch (field(d, "silenceInstance"), number(d, "ticks")) {
      | (Some(id), Some(ticks)) => r->Standin.Runtime.silence(~kind, ~id, ~ticks=ticks->Float.toInt)
      | _ => Ok()
      }
      switch silenced {
      | Error(why) => (400, errorJson(why))
      | Ok() =>
        let _ = r->Standin.Runtime.setRates(~kind, rates)
        (200, stateJson(r))
      }
    }
  }

let prefix = "/__inmemory/standins"

/** Answers a request under `/__inmemory/standins`, or `None` for any other path. */
let route = async (~method: string, ~path: string, ~body: string): option<(int, JSON.t)> =>
  if !(path->String.startsWith(prefix)) {
    None
  } else {
    switch running.contents {
    | None => Some((404, errorJson("no stand-ins are running on this platform")))
    | Some(r) =>
      let parsed = try JSON.parseOrThrow(body)->JSON.Decode.object catch {
      | _ => None
      }
      Some(
        switch (method, path->String.slice(~start=String.length(prefix)), parsed) {
        | ("GET", "" | "/", _) => (200, stateJson(r))
        | ("POST", "/send", Some(d)) => await sendByHand(r, d)
        | ("POST", "/switch", Some(d)) => switchKind(r, d)
        | ("POST", "/misbehave", Some(d)) => misbehave(r, d)
        | ("POST", _, None) => (400, errorJson("body is not a JSON object"))
        | _ => (404, errorJson(`no ${method} ${path}`))
        },
      )
    }
  }

// ── MCP ─────────────────────────────────────────────────────────────────────

let tool = (~name, ~description, ~properties, ~required, ~run) =>
  DomainMCP_Server.registerTool(
    ~name,
    ~definition={
      name,
      description,
      inputSchema: JSON.parseOrThrow(
        `{"type": "object", "properties": ${properties}, "required": ${required}}`,
      ),
    },
    ~handler=async (args, _) =>
      switch running.contents {
      | None => McpSdk_Helpers.toolError("No stand-ins are running on this platform.")
      | Some(r) =>
        let (status, json) = await run(r, args->JSON.Decode.object->Option.getOr(Dict.make()))
        status < 300
          ? McpSdk_Helpers.toolResult(JSON.stringify(json, ~space=2))
          : McpSdk_Helpers.toolError(JSON.stringify(json))
      },
  )

/** The stand-ins as tools of the domain MCP server, as the routes serve them. */
let registerTools = () => {
  tool(
    ~name="local_standins",
    ~description="The stand-ins of this local platform: each kind with its instances and their state, its misbehaviour and whether it runs, and the last sends with the doors' answers.",
    ~properties="{}",
    ~required="[]",
    ~run=async (r, _) => (200, stateJson(r)),
  )
  tool(
    ~name="local_standin_send",
    ~description="Sends one of a kind's messages for one instance now, through the door the real thing uses, and says what the door answered.",
    ~properties=`{"kind": {"type": "string"}, "id": {"type": "string"}, "message": {"type": "string"}, "fields": {"type": "object"}}`,
    ~required=`["kind", "id", "message"]`,
    ~run=sendByHand,
  )
  tool(
    ~name="local_standin_switch",
    ~description="Switches a kind on or off: off, its instances send nothing by themselves.",
    ~properties=`{"kind": {"type": "string"}, "on": {"type": "boolean"}}`,
    ~required=`["kind", "on"]`,
    ~run=async (r, d) => switchKind(r, d),
  )
  tool(
    ~name="local_standin_misbehave",
    ~description="Changes how a kind misbehaves: the chance (0 to 1) of silence, repeats, late sends and clock drift; with silenceInstance and ticks, silences that instance on purpose.",
    ~properties=`{"kind": {"type": "string"}, "silence": {"type": "number"}, "silenceInstance": {"type": "string"}, "repeats": {"type": "number"}, "late": {"type": "number"}, "drift": {"type": "number"}, "ticks": {"type": "number"}}`,
    ~required=`["kind"]`,
    ~run=async (r, d) => misbehave(r, d),
  )
}
