// The cross-provider contract for "which refusal did I just get" — see
// [docs/plans/appsync-refusal-vocabulary.md].
//
// An authorization gate has two ways to refuse and they ask the caller for
// opposite things. A caller whose credentials did not verify should present new
// ones. A caller who is simply not entitled will meet the same answer however
// many times they authenticate — asking them to sign in again ends a working
// session and fixes nothing.
//
// Both adapters draw that distinction. They express it in shapes that have
// nothing in common, because neither chose its own vocabulary: the local adapter
// sets `extensions.code` on a GraphQL error, and AppSync refuses at two
// different layers with `errorType` values the service picks. A client written
// against one is quietly wrong against the other — it reads for a key that is
// never present, finds nothing, and proceeds as though nothing was refused.
//
// So this module is a mapping, not an equality. It cannot make the two paths
// answer alike; `extensions` is not even reachable from an AppSync resolver.
// What it can do is let a caller ask the one question that matters — *was this
// about entitlement or about identity?* — and get an answer without knowing
// which adapter it is talking to.
//
// Every row here is an observed response, captured against a deployed API and
// the local server, not a reading of documentation.

/**
Which of the two refusals a response carries.

`Entitlement` — the caller was identified and is not permitted. Re-authenticating
changes nothing; the session is still good.

`Identity` — the caller was not identified. New credentials are the remedy, and
discarding the session is correct here and only here.
*/
type refusalKind =
  | Entitlement
  | Identity

/** The adapter a signal belongs to. */
type adapter =
  | Local
  | AppSync

/**
One observed refusal shape.

`discriminator` names where a client looks; `value` is what it finds there.
Together with `httpStatus` they are sufficient to classify a response — see
[classify], which is what callers should use rather than re-deriving this.
*/
type signal = {
  adapter: adapter,
  kind: refusalKind,
  httpStatus: int,
  discriminator: string,
  value: string,
}

/**
The `extensions.code` the local adapter sets for each refusal.

Exported so the adapter emits these rather than repeating the literals: a table
the emitting code does not read is documentation, and documentation drifts. The
AppSync values have no equivalent here — the service picks those, which is the
whole reason this module is a mapping rather than a shared constant.
*/
let localEntitlementCode = "FORBIDDEN"

/** See [localEntitlementCode]. */
let localIdentityCode = "UNAUTHORIZED"

/**
The correspondence both adapters are held to.

🚨 **The two AppSync values differ by a suffix and mean opposite things.**
`Unauthorized` is the entitlement refusal; `UnauthorizedException` is the identity
one. A client matching on the substring `"Unauthorized"` — the obvious thing to
write — collapses exactly the distinction this table exists to preserve, and
collapses it in the dangerous direction: it treats "you lack the role" as "your
session is dead" and signs the caller out of a session that was working.

Use [classify]. It is the only reason this table is data rather than prose.
*/
let signals: array<signal> = [
  {
    adapter: Local,
    kind: Entitlement,
    httpStatus: 200,
    discriminator: "extensions.code",
    value: localEntitlementCode,
  },
  {
    adapter: Local,
    kind: Identity,
    httpStatus: 200,
    discriminator: "extensions.code",
    value: localIdentityCode,
  },
  {
    adapter: AppSync,
    kind: Entitlement,
    httpStatus: 200,
    discriminator: "errors[].errorType",
    value: "Unauthorized",
  },
  {
    // The request never becomes a GraphQL execution: the service rejects it
    // before the schema is reached, so there is no field error to read and the
    // status line is the whole answer.
    adapter: AppSync,
    kind: Identity,
    httpStatus: 401,
    discriminator: "x-amzn-errortype",
    value: "UnauthorizedException",
  },
]

/**
Classify a refusal without knowing which adapter produced it.

Pass what the response actually carried: its status, the `errorType` of a GraphQL
error if there was one, and `extensions.code` if there was one. Returns `None`
when the response is not a refusal this contract recognises — which includes a
successful response, so a caller must not read `None` as "allowed".

Ordering matters and is the point of the function. The transport status is
checked first, because a 401 is the identity refusal on the AppSync path and its
`x-amzn-errortype` (`UnauthorizedException`) shares a prefix with the entitlement
value (`Unauthorized`). Matching the error type first would classify every
unidentified AppSync caller as merely unentitled.
*/
let classify = (
  ~httpStatus: int,
  ~errorType: option<string>=?,
  ~extensionsCode: option<string>=?,
): option<refusalKind> =>
  if httpStatus == 401 {
    Some(Identity)
  } else {
    switch extensionsCode {
    | Some(c) if c == localEntitlementCode => Some(Entitlement)
    | Some(c) if c == localIdentityCode => Some(Identity)
    | _ =>
      switch errorType {
      // Exact match, never a prefix or `includes` — see the warning on [signals].
      | Some("Unauthorized") => Some(Entitlement)
      | Some("UnauthorizedException") => Some(Identity)
      | _ => None
      }
    }
  }

/** The signals one adapter can produce. */
let signalsFor = (adapter: adapter): array<signal> =>
  signals->Array.filter(s => s.adapter == adapter)

/**
Whether a refusal means the caller should be asked to authenticate again.

The one decision the distinction exists to drive, kept here so no client has to
re-derive it — and so the wrong answer cannot be arrived at independently in
several places.
*/
let warrantsReauthentication = (kind: refusalKind): bool =>
  switch kind {
  | Identity => true
  | Entitlement => false
  }
