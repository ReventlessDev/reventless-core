// How a stack lays out the object stores its plugins declare, and how hard it
// protects them. Pure functions so both decisions are decidable and unit-
// testable without touching Pulumi — the same shape `Util_HostUiDomain` uses
// for the host-shell FQDN.
//
// Two decisions, deliberately independent:
//
//   layout      — one bucket per store, or one bucket per stack with `{store}/…`
//                 prefixes inside it
//   protection  — whether an accidental removal may destroy the store
//
// It is tempting to make one switch decide both, and that is wrong. `alpha`
// shares a bucket *and* holds hand-entered data worth protecting; a `pr-*`
// stack shares a bucket and must be destroyable or teardown leaks exactly the
// buckets sharing exists to save. Layout answers "how many buckets"; protection
// answers "is this data disposable". Those are different questions about the
// same stack.
//
// Why production alone gets per-store buckets: the growth term is
// `plugins × stores × stacks`, and stacks is the factor that actually grows —
// the stack allowlist admits `pr-*`, so per-PR environments multiply every
// plugin's every store against a 100-bucket account default. Production does
// not multiply. It is also the only environment where a bucket boundary (rather
// than a prefix boundary) is worth its cost, since the honest price of sharing
// is that per-store least-privilege degrades from a bucket ARN to a prefix ARN.

/** How many buckets a stack's declared stores get. */
type t =
  | PerStore
  | SharedBucket

/** Whether a store may be destroyed by an accidental removal. */
type protection =
  | Protected
  | Unprotected

/**
Stack-name prefixes whose stacks are disposable.

`pr-*` matches the stack allowlist's per-PR environments. A prefix rather than
an exact list because the whole point of these stacks is that nobody enumerates
them in advance.
*/
let defaultEphemeralPrefixes = ["pr-"]

/**
Production gets a bucket per store; every other stack shares one.

`prodStacks` comes from `Util_HostUiDomain.resolveProdStacks` — the same notion
of "production" that names the host-shell domain, on purpose.

Note this polarity **fails open**: a new production stack whose name is not on
the list (`production`, `live`, `prod-eu`) silently gets the weaker layout and
nothing errors. That is the accepted cost of keying off a name allowlist, paid
down by the list being config-overridable and by the deploy logging the layout
it chose — a silent fail-open is only dangerous while it is silent.
*/
let layoutFor = (~stack: string, ~prodStacks: array<string>): t =>
  prodStacks->Array.includes(stack) ? PerStore : SharedBucket

/**
Destroy semantics follow disposability, **not** layout.

`alpha` shares a bucket and is still protected: it declares
`reventless:wipeable`, but that authorises the reset tool to empty stores
*deliberately*, after a scope prompt and a typed confirmation. It does not say a
field rename may destroy a bucket by accident. Only stacks that are routinely
torn down are unprotected.
*/
let protectionFor = (~stack: string, ~ephemeralPrefixes: array<string>=defaultEphemeralPrefixes): protection =>
  ephemeralPrefixes->Array.some(p => stack->String.startsWith(p)) ? Unprotected : Protected

/**
The bucket a store's objects live in.

Per-store: `{plugin}-{store}`, so the physical name traces back to the
declaration that required it — a store rename becomes a visible replace in
review rather than a silent one. Shared: one `{stack}-stores` bucket for every
declared store on the stack.

Pulumi appends its own suffix for global uniqueness, so neither form has to
carry an account or region discriminator.
*/
let bucketNameFor = (~layout: t, ~stack: string, ~plugin: string, ~store: string): string =>
  switch layout {
  | PerStore => `${plugin}-${store}`
  | SharedBucket => `${stack}-stores`
  }

/**
The prefix a store's object keys are rooted at — the store name, in **both**
layouts.

This is the property that keeps the two layouts one model rather than a fork.
The presign service mints `{store}/{identity}{uuid}/{file}` either way, so the
stored ref is `/{store}/…` regardless of which bucket sits behind it, and only
the CDN origin differs. Refs live in an append-only event log: one that encoded
its bucket layout would be environment-specific and unrewritable, so a prod dump
restored into a PR stack would carry refs that cannot resolve.

The cost is a slightly redundant prefix inside a dedicated bucket
(`catalog-productImages/productImages/…`). Take the redundancy.
*/
let keyPrefixFor = (~store: string): string => store
