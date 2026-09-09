// Turns endpoints plus a login function into a ready `connection`.
//
// A connection is what a data set seeds against: an authenticated GraphQL
// client, the deployment's upload endpoints (empty when it serves no uploads),
// and a human label for the target. `make` is provider-agnostic — it prompts for
// credentials, calls the supplied `login` to obtain a bearer, and wires it onto
// the client via `useToken`. Where the bearer comes from (a local `/login`
// round-trip, a Cognito id token) is the caller's concern.

open Seed_Types

// ── Active role ───────────────────────────────────────────────────────────────
//
// Both platforms narrow a token to the single role the caller last chose, and on
// Cognito that choice is STORED — so an operator who acted as one role in the
// host shell gets a narrowed token from the next seed login, days later, with
// nothing in the seed's own environment to explain it. That is a refusal on the
// first gated call and no way out of the terminal.

/**
 * Applies an active-role choice, if the platform offers one. `None` clears the
 * choice and widens back to the caller's full membership.
 *
 * Returns the fresh bearer when the platform mints one itself, and `None` when
 * the choice is merely stored and a re-authentication is what picks it up. The
 * two platforms genuinely differ here: the local server re-issues on the spot,
 * while Cognito's pre-token-generation trigger reads the stored row on the next
 * login, so nothing changes until the seed authenticates again.
 *
 * Supplied by the platform adapter for the reason `~login` is: this package must
 * not learn which provider signed the token, and the routes are not alike — a
 * GraphQL mutation on one, an HTTP endpoint on the other.
 */
type roleSwitch = (~client: Seed_Client.t, ~role: option<string>) => promise<option<string>>

/** What a run should act as. `Full` is the default because seeding wants every
    right the account has; `Narrowed` exists so a run can deliberately act as one
    role — the only way to exercise what a restricted caller is refused. */
type roleChoice = Full | Narrowed(string)

// `SEED_ROLE`: a role name, or `full`/`all` to clear. Honoured whether or not the
// token arrived narrowed, so a deliberate narrowed run needs no TTY.
let roleFromEnv = (): option<roleChoice> =>
  Seed_Prompt.envValue("SEED_ROLE")->Option.map(v =>
    switch v->String.toLowerCase {
    | "full" | "all" | "none" | "clear" => Full
    | _ => Narrowed(v)
    }
  )

// Under route B the client mints uploads through the domain API's `Upload_Presign`
// mutation (authenticated by the same bearer as commands), so a connection needs no
// upload endpoint — just the authenticated client and whether uploads are skipped this
// run (`SEED_SKIP_UPLOADS`). Which store an asset uploads into is the caller's `~store`.
type connection = {
  client: Seed_Client.t,
  uploadsSkipped: bool,
  label: string,
  // Every account the platform's accounts file declares — `[]` when there was no
  // file, since the `REVENTLESS_DEMO_USER`/`REVENTLESS_DEMO_PASSWORD` path
  // bypasses it entirely. A data set resolves a demo owner through this, so the
  // id it seeds is the id the platform stamps rather than a literal that only
  // happens to match one platform's accounts.
  accounts: array<Seed_Users.user>,
  // The account this run authenticated as, and the id its bearer actually
  // carries — which is the only id available when there is no accounts file.
  caller: Seed_Users.user,
  callerId: option<string>,
  // The login this run authenticated with, kept so a data set can mint a second
  // client for another account. An owner-scoped read is only ever verified by
  // the account the rows belong to: the seeding client is elevated, and an
  // elevated token answers for every owner at once.
  login: (~username: string, ~password: string) => promise<string>,
  // How this platform stores an active-role choice, when it offers one at all.
  // `None` means the deployment has no such door (a unified-mode AWS API does
  // not carry `Platform_SetActiveRole`), and a narrowing can then only be
  // reported, not fixed from here.
  roleSwitch: option<roleSwitch>,
}

let announceIdentity = (client: Seed_Client.t, ~prefix: string="Acting as"): unit =>
  switch Seed_Client.identitySummary(client) {
  | Some(summary) => Console.log(`${prefix}: ${summary}`)
  | None => ()
  }

/**
 * Applies a role choice and leaves `client` holding a bearer that reflects it.
 *
 * The re-authentication is not optional bookkeeping: on Cognito the stored row
 * is read at token generation, so a run that set a role and kept its old bearer
 * would carry on with exactly the token it just tried to change.
 */
let applyRole = async (
  ~client: Seed_Client.t,
  ~roleSwitch: roleSwitch,
  ~login: (~username: string, ~password: string) => promise<string>,
  ~caller: Seed_Users.user,
  ~role: option<string>,
): unit => {
  let minted = await roleSwitch(~client, ~role)
  let token = switch minted {
  | Some(fresh) => fresh
  | None => await login(~username=caller.username, ~password=caller.password)
  }
  client->Seed_Client.useToken(token)
  // A second line rather than a replacement, and worded so the pair reads as a
  // change: the first says what the login gave, this says what the run proceeds
  // under, and a reader needs both to see that the switch actually took.
  client->announceIdentity(~prefix="Now acting as")
}

/**
 * Chooses what the run acts as, when the platform lets it choose.
 *
 * Deliberately quiet on a healthy run: an unnarrowed token has nothing to ask
 * about, so the common case gains no prompt. The menu appears only when the
 * bearer arrived narrowed — the case where the account list says one thing and
 * the token another, which is unreadable from the terminal without it.
 *
 * `SEED_ROLE` answers non-interactively and is honoured even when the token is
 * NOT narrowed, which is what makes a deliberate restricted run possible: acting
 * as one role is the only way to exercise what a restricted caller is refused.
 *
 * Without a TTY and without `SEED_ROLE` it proceeds untouched rather than
 * throwing. A narrowing is not always fatal — narrowed to Admin is fine — so
 * refusing to start would break runs that would have worked.
 */
let resolveRole = async (
  ~client: Seed_Client.t,
  ~roleSwitch: option<roleSwitch>,
  ~login: (~username: string, ~password: string) => promise<string>,
  ~caller: Seed_Users.user,
): unit =>
  switch roleSwitch {
  | None => ()
  | Some(roleSwitch) =>
    let narrowedFrom = Seed_Client.narrowedFrom(client)
    let chosen = switch roleFromEnv() {
    | Some(choice) => Some(choice)
    | None =>
      switch narrowedFrom {
      | Some(available) if available->Array.length > 1 && Seed_Prompt.hasTty() =>
        Console.log("")
        Console.log(
          "This token is narrowed to one role. Seeding needs every right the account has;",
        )
        Console.log("clearing also widens your host-shell session, which shares the stored choice.")
        let options = Array.concat(
          [(`full membership (${available->Array.join(", ")})`, Full)],
          available->Array.map(r => (r, Narrowed(r))),
        )
        Some(await Seed_Prompt.select(~title="Act as:", ~options, ~defaultIndex=0))
      | _ => None
      }
    }
    switch chosen {
    | None => ()
    | Some(Full) => await applyRole(~client, ~roleSwitch, ~login, ~caller, ~role=None)
    | Some(Narrowed(role)) =>
      await applyRole(~client, ~roleSwitch, ~login, ~caller, ~role=Some(role))
    }
  }

/**
 * Prompts for credentials, calls `login` to mint a bearer, and returns a
 * connection with that bearer already applied. `login` returns the bearer so a
 * single `useToken` path serves every provider.
 *
 * `roleSwitch` is the platform's active-role door, when it has one; supplying it
 * is what lets a narrowed token be widened here instead of in a browser.
 */
let make = async (
  ~label: string,
  ~endpoint: string,
  ~login: (~username: string, ~password: string) => promise<string>,
  ~roleSwitch: option<roleSwitch>=?,
  ~localDefaults: bool=false,
): connection => {
  // `SEED_SKIP_UPLOADS` forces the upload phase to no-op — seed domain data fast, or
  // skip a broken/absent upload path without editing the data set. The data set reads
  // `connection.uploadsSkipped` and reports the skip.
  let uploadsSkipped = Seed_Upload.uploadsSkipped()
  let {caller, accounts} = await Seed_Prompt.credentials(~localDefaults)
  let token = await login(~username=caller.username, ~password=caller.password)
  let client = Seed_Client.make(~config={endpoint: endpoint})
  client->Seed_Client.useToken(token)
  // What the bearer grants, which is not always what the account list showed: a
  // token narrowed to one role presents that role alone. Said at login so the
  // run starts from the identity it will actually be refused or served under.
  announceIdentity(client)
  // Offered before anything is probed or written, so a narrowing is settled
  // while the run can still be redirected rather than after a refusal.
  await resolveRole(~client, ~roleSwitch, ~login, ~caller)
  {
    client,
    uploadsSkipped,
    label,
    accounts,
    caller,
    callerId: Seed_Client.callerId(client),
    login,
    roleSwitch,
  }
}

/**
 * A second authenticated client, for one of the accounts the platform's accounts
 * file declares. Same endpoint, same login route, a different bearer.
 *
 * It exists so a data set can read back what it seeded as the account the rows
 * belong to. The seeding client cannot answer that question: it is elevated, so
 * an owner-scoped view counts every owner's rows for it and reads non-empty
 * whether or not a single row is reachable by the person it was seeded for.
 */
let clientFor = async (c: connection, ~account: Seed_Users.user): Seed_Client.t => {
  let token = await c.login(~username=account.username, ~password=account.password)
  let client = Seed_Client.make(~config={endpoint: Seed_Client.endpoint(c.client)})
  client->Seed_Client.useToken(token)
  client
}

/**
 * A login function backed by an HTTP login endpoint (the local dev
 * `/__inmemory/login` shape: POST `{username, password}` → `{token}`). Reuses
 * `Seed_Client.login` but hands the token back for `useToken`.
 */
let viaLoginEndpoint = (~loginEndpoint: string) =>
  async (~username: string, ~password: string): string => {
    let client = Seed_Client.make(
      ~config={endpoint: loginEndpoint, loginEndpoint, username, password},
    )
    await Seed_Client.login(client)
    switch Seed_Client.currentToken(client) {
    | Some(token) => token
    | None => throw(Failed(`login at ${loginEndpoint} returned no token`))
    }
  }

/**
 * The local dev platform's active-role door: POST `/__inmemory/switch-role` with
 * `{activeRole}` (null to clear) and the current bearer, which answers with a
 * freshly minted one.
 *
 * The local server re-issues on the spot rather than storing a choice, so this
 * returns the new token and no re-authentication follows. Its narrowing is also
 * per-session, which is why a local seed never arrives narrowed on its own —
 * this exists for a *deliberate* `SEED_ROLE` run, which is where a restricted
 * caller's refusals can be exercised without a deployed stack.
 */
let viaSwitchRoleEndpoint = (~switchRoleEndpoint: string): roleSwitch =>
  async (~client: Seed_Client.t, ~role: option<string>) => {
    let token = switch Seed_Client.currentToken(client) {
    | Some(t) => t
    | None => throw(Failed("switch-role: no bearer to present — log in first"))
    }
    // Clearing OMITS the key rather than sending `null`. The local handler reads
    // its body through `Obj.magic` into an `option<string>`, and ReScript spells
    // absence `undefined` — so a JSON `null` arrives as a present value and the
    // server tries to act as a role literally named "null", refusing with
    // `Cannot act as "null": not a group this user holds`. An absent key is the
    // only thing it reads as "no role", which is what widens back to full.
    let body = JSON.stringify(
      JSON.Encode.object(
        switch role {
        | Some(r) => Dict.fromArray([("activeRole", JSON.Encode.string(r))])
        | None => Dict.make()
        },
      ),
    )
    let res = try await Seed_Client.fetch(
      switchRoleEndpoint,
      {
        method: "POST",
        headers: Dict.fromArray([
          ("content-type", "application/json"),
          ("authorization", `Bearer ${token}`),
        ]),
        body,
      },
    ) catch {
    | _ => throw(Failed(`switch-role: cannot reach ${switchRoleEndpoint}`))
    }
    let json = await res->Seed_Client.responseJson
    if !(res->Seed_Client.responseOk) {
      throw(
        Failed(
          `switch-role at ${switchRoleEndpoint} failed with HTTP ${res
            ->Seed_Client.responseStatus
            ->Int.toString}: ${JSON.stringify(json)}`,
        ),
      )
    }
    switch json->Seed_Client.field("token")->Option.flatMap(Seed_Client.asString) {
    | Some(fresh) => Some(fresh)
    | None => throw(Failed(`switch-role at ${switchRoleEndpoint} returned no token`))
    }
  }

let envOr = (key: string, fallback: string): string =>
  Seed_Prompt.envValue(key)->Option.getOr(fallback)

/**
 * A ready `connect` thunk for the local dev platform, with the localhost
 * defaults baked in and overridable per endpoint (arg, then env var, then
 * default). Empty input at the credential prompt falls back to `admin`/`admin`.
 *
 * No upload endpoint: uploads mint through the domain API's `Upload_Presign` mutation
 * on the same `graphql` endpoint, with the store passed per asset.
 */
let local = (~graphql=?, ~login=?, ()): (unit => promise<connection>) => {
  let endpoint =
    graphql->Option.getOr(envOr("REVENTLESS_GRAPHQL_ENDPOINT", "http://localhost:4000/graphql"))
  let loginEndpoint =
    login->Option.getOr(
      envOr("REVENTLESS_LOGIN_ENDPOINT", "http://localhost:4000/__inmemory/login"),
    )
  // The switch-role route sits beside the login one on the same server, so it is
  // derived rather than configured — a second env var could name a different
  // host from the login it is supposed to re-issue, which is the mismatch
  // `LocalSeedTarget.loginFor` exists to prevent one level up.
  let switchRoleEndpoint =
    loginEndpoint->String.replace("/__inmemory/login", "/__inmemory/switch-role")
  () =>
    make(
      ~label="local",
      ~endpoint,
      ~login=viaLoginEndpoint(~loginEndpoint),
      ~roleSwitch=viaSwitchRoleEndpoint(~switchRoleEndpoint),
      ~localDefaults=true,
    )
}
