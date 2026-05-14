// In-memory `Auth_Adapter.Provider` implementation. Designed for local
// development and integration tests — no cryptographic verification.
//
// Header semantics (per host-ui-login-core plan, stage A2):
//   X-User: <username>   → resolve identity from the in-process user store
//   X-Groups: A,B,C       → override the resolved identity's groups
//   neither               → Identity.anonymous
//
// A4 will layer bearer-token issuance + a YAML-backed user store on top of
// this; A2 ships built-in `user` / `admin` identities so plain header-based
// flows work out of the box.

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

// ── Provider implementation ───────────────────────────────────────────────

type authConfig = unit

let authenticate = async (
  ctx: ReventlessCore.Auth_Adapter.requestContext,
): Identity.authResult => {
  let userHeader = getHeader(ctx.headers, "X-User")
  let groupsHeader = getHeader(ctx.headers, "X-Groups")
  switch userHeader {
  | None =>
    switch groupsHeader {
    | None => Anonymous
    | Some(g) =>
      // X-Groups without X-User: anonymous identity tagged with the groups.
      // Useful for tests that exercise group-only authorization paths.
      Authenticated({
        ...Identity.anonymous,
        groups: parseGroups(g),
      })
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

let make = (~name as _: string, ~opts as _: option<Pulumi.ComponentResource.options>=?): Pulumi.Output.t<authConfig> =>
  Pulumi.Output.make()
