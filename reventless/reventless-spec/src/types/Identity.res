S.enableJson()

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
