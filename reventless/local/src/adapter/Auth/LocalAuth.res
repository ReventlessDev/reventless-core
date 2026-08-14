// In-memory `Auth_Adapter.Provider` implementation. Designed for local
// development and integration tests.
//
// Header semantics (host-ui-login-core stages A2 + A4):
//   Authorization: Bearer <token>  → decode + HMAC-verify a Login-issued token
//   X-User: <username>             → resolve identity from the user store
//   X-Groups: A,B,C                → override the resolved identity's groups
//   none of the above              → Authenticated(defaultUser) (dev default)
//
// Stage A4 adds the `Login` submodule (token issuance + verification) and
// the companion `UserStore` module (YAML hydration).

open Reventless

// ── Built-in identities ────────────────────────────────────────────────────

let defaultUser: Identity.t = {
  userId: "local-user",
  username: "user",
  groups: ["User"],
  provider: InMemory,
}

let adminUser: Identity.t = {
  userId: "local-admin",
  username: "admin",
  groups: ["Admin", "User"],
  provider: InMemory,
}

// ── User registry ─────────────────────────────────────────────────────────
//
// A `dict<Identity.t>` keyed by `username`. A4 hydrates this from
// `.reventless/users.yaml`; tests inject via `registerUser`.

let initialUsers = () =>
  Dict.fromArray([("user", defaultUser), ("admin", adminUser)])

let users: ref<dict<Identity.t>> = ref(initialUsers())

let registerUser = (~username: string, ~identity: Identity.t): unit =>
  users.contents->Dict.set(username, identity)

let resetUsers = (): unit => users := initialUsers()

let lookupUser = (username: string): option<Identity.t> =>
  users.contents->Dict.get(username)

// ── Header parsing ────────────────────────────────────────────────────────

let parseGroups = (s: string): array<string> =>
  s
  ->String.split(",")
  ->Array.map(g => g->String.trim)
  ->Array.filter(g => g !== "")

// HTTP headers are case-insensitive; the context factory in
// DomainGraphQL_Server normalises keys to lower-case before calling
// authenticate.
let getHeader = (headers: dict<string>, name: string): option<string> =>
  headers->Dict.get(name->String.toLowerCase)

// ── Login (Stage A4 — token issuance) ──────────────────────────────────────
//
// Issues opaque tokens of the form `<base64url-payload>.<base64url-sig>` where
// payload = JSON(Identity.t) and sig = HMAC-SHA256(payload, secret). The
// secret is process-local (random 32-byte hex at first use) and can be pinned
// for tests via `Login.setTokenSecret`.
//
// Not security-grade — local dev only. AWS deployments verify Cognito-issued
// JWTs at AppSync (Stage D) and never see these tokens.

module Login = {
  type credentials = {password: string, identity: Identity.t}

  // Hydrated by `UserStore` at platform start; tests can inject directly.
  let store: ref<dict<credentials>> = ref(Dict.make())

  let setCredentials = (~username: string, ~password: string, ~identity: Identity.t): unit => {
    store.contents->Dict.set(username, {password, identity})
    // Mirror into the authenticate-side user registry so X-User flows still
    // resolve a Login-registered user.
    users.contents->Dict.set(username, identity)
  }

  let resetStore = (): unit => {
    store := Dict.make()
  }

  // ── HMAC secret (lazy) ──
  //
  // Resolved once on first use, from three sources in order:
  //
  //   1. `REVENTLESS_INMEMORY_TOKEN_SECRET` (≥16 chars) — an explicit pin, for
  //      a deployment or a test that wants to state the secret itself.
  //   2. `.reventless/token-secret` beside the platform's other local state,
  //      minted on the first boot that finds the directory and reused by every
  //      boot after. This is what keeps a logged-in tab working across a
  //      restart, which is not a nicety: `tsx watch` re-execs the process on
  //      every ReScript rebuild, so a per-process secret logs the developer out
  //      several times an hour, mid-task, with a "reconnecting" spinner as the
  //      only explanation.
  //   3. A random 32 bytes, per process — today's behaviour, kept for the run
  //      that has no `.reventless/` to write to.
  //
  // The directory is used but never created. Its presence is what distinguishes
  // a platform someone develops against — `pnpm run setup` puts `users.yaml`
  // there, so anything with logins to preserve has one — from a unit test, and
  // an auth module that made directories would leave one in every test's cwd.
  //
  // Local dev only, as the whole module is: these tokens are not security-grade
  // and AWS never sees them. The file sits in a gitignored directory beside
  // `users.yaml`, which already holds plaintext dev passwords.

  let _secretFileName = "token-secret"
  let _secretDir = (): string => NodePath.join([NodeProcess.cwd(), ".reventless"])

  let _mint = (): string => NodeCrypto.randomBytes(32)->NodeCrypto.bufferToString("hex")

  // A short or empty file is treated as absent rather than as an error: it is
  // either a half-written mint or somebody's experiment, and either way the
  // recovery — mint a new one over it — is the same and costs one login.
  let _readPersistedAt = (path: string): option<string> =>
    switch NodeFs.readFileSync(path) {
    | contents if String.length(String.trim(contents)) >= 16 => Some(String.trim(contents))
    | _ => None
    | exception _ => None
    }

  // Failure to write is not failure to boot. A read-only checkout still gets a
  // working platform; what it loses is the session surviving the next restart,
  // which is exactly what it had before this existed.
  let _persistAt = (path: string, secret: string): unit =>
    switch NodeFs.writeFileSync(path, secret) {
    | () => ()
    | exception _ => ()
    }

  /** The ladder, against a stated directory. Separate from `_getSecret` so a
      test can exercise every rung without a `.reventless/` in its own working
      directory — which it must not have, since the rule below is precisely that
      the directory's presence decides whether anything is written at all. */
  let _resolveIn = (~dir: string): string =>
    switch NodeProcess.env->Dict.get("REVENTLESS_INMEMORY_TOKEN_SECRET") {
    | Some(envSecret) if String.length(envSecret) >= 16 => envSecret
    | _ =>
      if NodeFs.existsSync(dir) {
        let path = NodePath.join([dir, _secretFileName])
        switch _readPersistedAt(path) {
        | Some(persisted) => persisted
        | None =>
          let minted = _mint()
          _persistAt(path, minted)
          minted
        }
      } else {
        _mint()
      }
    }

  let _secret: ref<option<string>> = ref(None)
  let _getSecret = (): string =>
    switch _secret.contents {
    | Some(s) => s
    | None =>
      let s = _resolveIn(~dir=_secretDir())
      _secret := Some(s)
      s
    }

  let setTokenSecret = (s: string): unit => _secret := Some(s)

  let _sign = (payload: string): string =>
    NodeCrypto.createHmac("sha256", _getSecret())
    ->NodeCrypto.hmacUpdate(payload)
    ->NodeCrypto.hmacDigest("base64url")

  // base64url over arbitrary JSON strings: btoa-encode + URL-safe alphabet,
  // strip `=` padding. Avoids pulling in Buffer for a single-line conversion.
  @val external _btoa: string => string = "btoa"
  @val external _atob: string => string = "atob"

  let _b64urlEncode = (s: string): string =>
    _btoa(s)
    ->String.replaceAll("+", "-")
    ->String.replaceAll("/", "_")
    ->String.replaceAll("=", "")

  let _b64urlDecode = (s: string): option<string> => {
    let padLen = mod(4 - mod(s->String.length, 4), 4)
    let padded = s ++ String.repeat("=", padLen)
    let std = padded->String.replaceAll("-", "+")->String.replaceAll("_", "/")
    try {
      Some(_atob(std))
    } catch {
    | _ => None
    }
  }

  /**
   The claim names a narrowed token carries, shared with the Cognito minting
   path — a client must not have to know which platform signed its token to read
   its own active role. See `ReventlessCore.Auth_ActiveRole` for what each means
   and why `availableRoles` is never an authorization input.

   Both are present only on a narrowed token, which is what keeps an ordinary
   login byte-identical to what it minted before any of this existed: an
   unnarrowed token's `groups` already *are* the full membership, so there is
   nothing to remember.
   */
  let activeRoleClaim = ReventlessCore.Auth_ActiveRole.activeRoleClaim
  let availableRolesClaim = ReventlessCore.Auth_ActiveRole.availableRolesClaim

  /**
   Narrow an identity to one of its own roles.

   `Error` when the role is not one the caller holds. Refusing rather than
   ignoring is the security-critical line of this feature: a request for a group
   the user does not have is either confused or hostile, and a token that
   silently does not match what was asked for serves neither. Because the check
   is a subset test against actual membership, a tampering client can only ever
   reduce its own privilege.
   */
  let narrow = (identity: Identity.t, ~activeRole: string): result<Identity.t, string> =>
    if !(identity.groups->Array.includes(activeRole)) {
      Error(`Cannot act as "${activeRole}": not a group this user holds`)
    } else {
      let claims = switch identity.claims {
      | Some(existing) => Dict.fromArray(existing->Dict.toArray)
      | None => Dict.make()
      }
      claims->Dict.set(activeRoleClaim, activeRole)
      claims->Dict.set(availableRolesClaim, identity.groups->Array.join(","))
      Ok({...identity, groups: [activeRole], claims})
    }

  /**
   Verifies credentials and returns a signed token (or an error string).

   `activeRole` narrows the minted token to one of the caller's own roles; unset
   mints exactly what it has always minted.
   */
  let issue = async (
    ~username: string,
    ~password: string,
    ~activeRole: option<string>=?,
  ): result<string, string> =>
    switch store.contents->Dict.get(username) {
    | Some({password: stored, identity}) if stored === password =>
      switch switch activeRole {
      | None => Ok(identity)
      | Some(role) => identity->narrow(~activeRole=role)
      } {
      | Error(_) as e => e
      | Ok(minted) =>
        let json = minted->S.reverseConvertToJsonOrThrow(Identity.schema)->JSON.stringify
        let payload = _b64urlEncode(json)
        let sig = _sign(payload)
        Ok(`${payload}.${sig}`)
      }
    | _ => Error("Invalid credentials")
    }

  /**
   The identity a token carries, for a caller that has just been issued one.

   Exists so the login response can echo the *minted* identity rather than the
   stored one. They differ exactly when the token is narrowed, and a response
   disagreeing with the token it accompanies would leave the client a step behind
   the server from its very first request.
   */
  let mintedIdentity = (~username: string, ~activeRole: option<string>): option<Identity.t> =>
    store.contents
    ->Dict.get(username)
    ->Option.flatMap(({identity, _}) =>
      switch activeRole {
      | None => Some(identity)
      | Some(role) =>
        switch identity->narrow(~activeRole=role) {
        | Ok(narrowed) => Some(narrowed)
        | Error(_) => None
        }
      }
    )

  /**
   * Returns the embedded Identity if signature verifies and the payload
   * decodes; `None` for any tampered, malformed, or unsigned token.
   */
  let verifyAndDecode = (token: string): option<Identity.t> => {
    let parts = token->String.split(".")
    switch (parts->Array.get(0), parts->Array.get(1)) {
    | (Some(payload), Some(sig)) if _sign(payload) === sig =>
      _b64urlDecode(payload)->Option.flatMap(json =>
        try {
          Some(json->JSON.parseOrThrow->S.parseOrThrow(Identity.schema))
        } catch {
        | _ => None
        }
      )
    | _ => None
    }
  }

  /**
   Re-mint an existing session as one of the caller's roles.

   A switch is not a fresh login: the client holds a token, not a password, and
   asking for the password again to change role would make an ordinary
   navigation a re-authentication. Possession of a token this server signed is
   already proof of the credentials that produced it.

   🚨 **Membership is re-read from the store, never from the presented token.**
   A narrowed token carries `availableRolesClaim`, and widening back by trusting
   it would make the record of what a caller gave up into the authority for
   getting it back. The signature makes that claim authentic, not correct: the
   store is where membership actually lives, and re-reading it means a role
   revoked since the token was issued cannot be switched into.

   `activeRole` unset widens back to full membership — which is not a privilege
   escalation, because the subset being widened *to* is the one the store says
   the caller has.
   */
  let reissue = (~token: string, ~activeRole: option<string>): result<string, string> =>
    switch verifyAndDecode(token) {
    | None => Error("Invalid token")
    | Some(presented) =>
      switch store.contents->Dict.get(presented.username) {
      | None => Error("Unknown user")
      | Some({identity, _}) =>
        switch switch activeRole {
        | None => Ok(identity)
        | Some(role) => identity->narrow(~activeRole=role)
        } {
        | Error(_) as e => e
        | Ok(minted) =>
          let json = minted->S.reverseConvertToJsonOrThrow(Identity.schema)->JSON.stringify
          let payload = _b64urlEncode(json)
          Ok(`${payload}.${_sign(payload)}`)
        }
      }
    }

}

// ── Provider implementation ───────────────────────────────────────────────

type authConfig = unit

let _bearerToken = (header: string): option<string> =>
  if header->String.startsWith("Bearer ") {
    Some(header->String.slice(~start=7, ~end=header->String.length)->String.trim)
  } else {
    None
  }

let authenticate = async (
  ctx: ReventlessCore.Auth_Adapter.requestContext,
): Identity.authResult => {
  // Decoding order: Bearer (when signature valid) → X-User/X-Groups → default.
  // A *present* Bearer that fails verification is rejected (AuthError) rather
  // than falling through to defaultUser — otherwise a client whose token was
  // invalidated (e.g. process-local HMAC secret rotated on restart) would
  // silently keep working as defaultUser, and the host-shell `on401` logout
  // path would never fire. No-Authorization stays permissive (defaultUser)
  // so anonymous dev flows still work.
  let bearerHeader = getHeader(ctx.headers, "Authorization")->Option.flatMap(_bearerToken)
  switch bearerHeader {
  | Some(token) =>
    switch Login.verifyAndDecode(token) {
    | Some(identity) => Authenticated(identity)
    | None => AuthError("Invalid bearer token")
    }
  | None =>
    let userHeader = getHeader(ctx.headers, "X-User")
    let groupsHeader = getHeader(ctx.headers, "X-Groups")
    switch userHeader {
    | None =>
      switch groupsHeader {
      | None =>
        // No headers: in-memory mode defaults to defaultUser so local dev
        // against an AllowAuthenticated-defaulted backend "just works" without
        // setting headers. Anonymous behaviour is reachable only by building
        // an Identity.anonymous explicitly in code.
        Authenticated(defaultUser)
      | Some(g) =>
        // X-Groups without X-User: defaultUser identity with the requested
        // groups. Useful for tests that exercise group-only authorization paths.
        Authenticated({...defaultUser, groups: parseGroups(g)})
      }
    | Some(username) =>
      switch lookupUser(username) {
      | None => Anonymous
      | Some(identity) =>
        let withGroups = switch groupsHeader {
        | Some(g) => {...identity, groups: parseGroups(g)}
        | None => identity
        }
        Authenticated(withGroups)
      }
    }
  }
}

let make = (~name as _: string, ~opts as _: option<Pulumi.ComponentResource.options>=?): Pulumi.Output.t<authConfig> =>
  Pulumi.Output.make()
