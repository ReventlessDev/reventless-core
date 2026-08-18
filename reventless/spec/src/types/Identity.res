
/** Identity provider that authenticated the user. */
@schema
type provider = Cognito | InMemory | Custom(string)

/**
Per-request identity carried through RequestContext.

NOT persisted in events — only `userId` is stored as `meta.user`.
Full identity lives in-memory for the duration of a single request.
*/
@schema
type t = {
  userId: string,
  username: string,
  groups: array<string>,
  claims?: dict<string>,
  provider: provider,
}

let anonymous: t = {
  userId: "anonymous",
  username: "anonymous",
  groups: [],
  provider: InMemory,
}

let hasGroup = (identity: t, group: string): bool =>
  identity.groups->Array.includes(group)

let getClaim = (identity: t, key: string): option<string> =>
  switch identity.claims {
  | Some(claims) => claims->Dict.get(key)
  | None => None
  }

/**
Outcome of a single `Auth_Adapter.Provider.authenticate` call.
`AuthError` carries a short human-readable reason (logged, not returned
verbatim to clients) — useful for diagnosing failed bearer-token validation.
*/
type authResult =
  | Authenticated(t)
  | Anonymous
  | AuthError(string)
