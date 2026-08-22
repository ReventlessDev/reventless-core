// The cross-provider contract for "a caller holding several roles acting as one
// of them" — see [docs/plans/active-role-narrows-the-token.md].
//
// The narrowing itself is minted in two places that cannot share code: the local
// platform signs its own tokens (`LocalAuth.Login`), and on AWS the minting point
// is Cognito's pre-token-generation trigger, running in Cognito's runtime against
// Cognito's event shape. What the two must agree on is exactly what lives here:
// the claim names a client reads, and the table of cases the subset rule has to
// satisfy on both paths.

/**
Claim naming the role the caller chose to act as. Present only on a narrowed
token, so its presence *is* the answer to "am I acting as one of my roles?".

Kept apart from the group claim even though a narrowed token's groups are exactly
this one role, because the two say different things: groups are what every
enforcement point evaluates, and this is what the caller asked for.
*/
let activeRoleClaim = "activeRole"

/**
Claim naming the roles the caller gave up by narrowing — their full membership,
comma-joined.

🚨 **Never read this for authorization.** It exists so a client can offer the
switch back, and it is by definition wider than what the caller is currently
permitted. Every enforcement point reads the group claim; this is the one piece
of an identity that deliberately describes privilege the caller does *not*
currently have.
*/
let availableRolesClaim = "availableRoles"

/**
Claim naming a stored role that was *not* applied because the caller no longer
holds it.

Only the Cognito path can produce this. A stored preference outlives the
membership that justified it, and the trigger meets that on an ordinary refresh
with no client asking for anything — so it cannot refuse the way the local path
refuses a request. It mints the full set instead, and says so here: without this
claim a caller would be silently un-narrowed with nothing to explain why the role
they picked stopped taking effect.
*/
let staleRoleClaim = "activeRoleStale"

// 🚨 **State that narrows an identity is scoped to the identity provider, not to
// the platform.**
//
// A provider has one minting point, and narrowing works by driving it. Keep the
// state a platform-scoped resource and two deployments sharing one provider each
// drive their own copy — whichever holds the minting point reads state the other
// never writes, so a role switch reports success and changes nothing. Each half
// is individually correct, so nothing short of two deployments can observe it.
//
// On AWS that is a pool's single `PreTokenGeneration` slot and the
// `platform:activeRoleStore` that follows it; elsewhere the shape differs and the
// rule does not. It cannot be a `conformanceCases` entry — those are
// `(membership, requested) → expected`, and this is about *where two deployments
// keep state*. See [docs/plans/active-role-store-scoped-to-the-pool.md].

/**
The conformance table §6 of the plan requires: the same (membership, requested,
expected) cases run against both minting paths, so the two implementations cannot
drift on the question that carries the security.

It lives in product code rather than in either package's tests because ReScript
test directories are `type: dev` and therefore invisible across a package
boundary — and a table copied into two test suites is exactly the drift it exists
to prevent.

`expected` is the group set the minted token must carry. `None` means the request
must be **refused** rather than honoured, ignored, or reduced to the empty set —
the distinction §3 turns on. A path with no client to refuse (the trigger, reading
stored state) resolves `None` by minting `membership` and marking
[staleRoleClaim]; a path answering a live request refuses it.
*/
type conformanceCase = {
  label: string,
  membership: array<string>,
  requested: option<string>,
  expected: option<array<string>>,
}

let conformanceCases: array<conformanceCase> = [
  {
    label: "no role requested mints exactly what it always minted",
    membership: ["Fulfilment", "Shopper"],
    requested: None,
    expected: Some(["Fulfilment", "Shopper"]),
  },
  {
    label: "a held role narrows to that role alone",
    membership: ["Fulfilment", "Shopper"],
    requested: Some("Shopper"),
    expected: Some(["Shopper"]),
  },
  {
    label: "the other held role narrows just as well",
    membership: ["Fulfilment", "Shopper"],
    requested: Some("Fulfilment"),
    expected: Some(["Fulfilment"]),
  },
  {
    label: "a role the caller does not hold is refused, never widened into",
    membership: ["Fulfilment", "Shopper"],
    requested: Some("Admin"),
    expected: None,
  },
  {
    label: "a sole role narrows to itself rather than being a special case",
    membership: ["Shopper"],
    requested: Some("Shopper"),
    expected: Some(["Shopper"]),
  },
  {
    label: "a caller holding nothing can request nothing",
    membership: [],
    requested: Some("Shopper"),
    expected: None,
  },
  {
    label: "the empty string is a request, and one no caller can hold",
    membership: ["Shopper"],
    requested: Some(""),
    expected: None,
  },
  {
    label: "group names are matched exactly, not case-insensitively",
    membership: ["Shopper"],
    requested: Some("shopper"),
    expected: None,
  },
]
