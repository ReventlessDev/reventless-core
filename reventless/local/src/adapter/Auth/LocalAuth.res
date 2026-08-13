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
  // Reads `REVENTLESS_INMEMORY_TOKEN_SECRET` once on first use. When the env
  // var is set (≥16 chars) the issued tokens survive process restarts, which
  // matches the dev loop's expectation that a logged-in tab keeps working
  // after a backend reload. When unset, falls back to a random per-process
  // secret — secure for ephemeral test runs but invalidates every previously
  // issued token on every restart.

  let _secret: ref<option<string>> = ref(None)
  let _getSecret = (): string =>
    switch _secret.contents {
    | Some(s) => s
    | None =>
      let s = switch NodeProcess.env->Dict.get("REVENTLESS_INMEMORY_TOKEN_SECRET") {
      | Some(envSecret) if String.length(envSecret) >= 16 => envSecret
      | _ => NodeCrypto.randomBytes(32)->NodeCrypto.bufferToString("hex")
      }
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
   Claim naming the role the caller chose to act as. Present only on a narrowed
   token, so its presence *is* the answer to "am I acting as one of my roles?".

   Kept apart from `groups` even though a narrowed token's groups are exactly
   this one role, because the two say different things: `groups` is what every
   enforcement point evaluates, and this is what the caller asked for. A client
   reading the choice out of the group array would be depending on the current
   shape of the narrowing rather than on the choice itself.
   */
  let activeRoleClaim = "activeRole"

  /**
   Claim naming the roles the caller gave up by narrowing — their full
   membership, comma-joined as the `X-Groups` header already joins groups.

   🚨 **Never read this for authorization.** It exists so a client can offer the
   switch back, and it is by definition wider than what the caller is currently
   permitted. Every enforcement point in the system reads `groups`; this claim is
   the one piece of an identity that deliberately describes privilege the caller
   does *not* currently have.

   Present only on a narrowed token, which is also what keeps an ordinary login
   byte-identical to what it minted before any of this existed: an unnarrowed
   token's `groups` already *are* the full membership, so there is nothing to
   remember.
   */
  let availableRolesClaim = "availableRoles"

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
