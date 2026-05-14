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
  type buf
  @module("node:crypto") external _randomBytes: int => buf = "randomBytes"
  @send external _bufToString: (buf, string) => string = "toString"
  type hmac
  @module("node:crypto") external _createHmac: (string, string) => hmac = "createHmac"
  @send external _update: (hmac, string) => hmac = "update"
  @send external _digest: (hmac, string) => string = "digest"

  let _secret: ref<option<string>> = ref(None)
  let _getSecret = (): string =>
    switch _secret.contents {
    | Some(s) => s
    | None =>
      let s = _randomBytes(32)->_bufToString("hex")
      _secret := Some(s)
      s
    }

  let setTokenSecret = (s: string): unit => _secret := Some(s)

  let _sign = (payload: string): string =>
    _createHmac("sha256", _getSecret())->_update(payload)->_digest("base64url")

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

  /** Verifies credentials and returns a signed token (or an error string). */
  let issue = async (~username: string, ~password: string): result<string, string> =>
    switch store.contents->Dict.get(username) {
    | Some({password: stored, identity}) if stored === password =>
      let json = identity->S.reverseConvertToJsonOrThrow(Identity.schema)->JSON.stringify
      let payload = _b64urlEncode(json)
      let sig = _sign(payload)
      Ok(`${payload}.${sig}`)
    | _ => Error("Invalid credentials")
    }

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
