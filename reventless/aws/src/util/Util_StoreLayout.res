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

/** Whether the platform provisions everything a plugin's fields declare. */
type coverage =
  /** Every declared store is provisioned. */
  | Covered
  /** The platform provisions no stores at all — it has not adopted capability
      provisioning, which is a different situation from getting it wrong. */
  | NotAdopted(array<string>)
  /** The platform provisions stores, but not these. Carries what it does
      provision, because the usual cause is a near-miss worth showing. */
  | Missing({missing: array<string>, provisioned: array<string>})

/** Which distribution fronts the declared stores. */
type serving =
  /** No store is declared, so nothing is served. */
  | NoStores
  /** The host shell's own distribution serves them same-origin, so a minted
      `/{prefix}/…` ref resolves relative and there is no base URL. */
  | HostShell
  /** The platform fronts them itself, because no host shell is deployed. */
  | PlatformOwned

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
The prefix a store's object keys are rooted at — `{plugin}/{store}`, in **both**
layouts.

Layout-invariance is what keeps the two layouts one model rather than a fork.
The presign service mints `{prefix}/{identity}/{uuid}/{file}` either way, so the
stored ref is `/{prefix}/…` regardless of which bucket sits behind it, and only
the CDN origin differs. Refs live in an append-only event log: a prefix that
encoded its bucket layout would be environment-specific and unrewritable, so a
prod dump restored into a PR stack would carry refs that cannot resolve. Plugin
and store are stack-invariant, so qualifying by plugin costs none of that.

Qualified because the prefix is a **platform-global** namespace: one distribution
fronts every store bucket and takes one cache behavior per prefix, so a bare
store name made two plugins declaring `productImages` unroutable — in either
layout, since the per-store layout still lands both prefixes on the one
distribution. Qualifying narrows uniqueness from "per platform" to "per plugin",
which is what plugin isolation wants and what a platform composing plugins it
did not author needs.

The cost is a slightly redundant prefix inside a dedicated bucket
(`catalog-productImages/Catalog/productImages/…`). Take the redundancy.

**Changing this string is breaking.** Minted refs are `/{prefix}/…` in an
append-only event log, so objects written under an earlier prefix become
unreachable and their refs unresolvable. There is deliberately no grandfathering
machinery: a stack that predates a change to this function empties its stores
(`seed:reset`, which wipes per plugin) and re-seeds. Carrying a permanent prefix
set to spare a disposable stack one wipe is the worse trade.
*/
let keyPrefixFor = (~plugin: string, ~store: string): string => `${plugin}/${store}`

/**
Who serves the declared stores — and the answer is never "both".

A store's bucket blocks public policy and takes its read grant solely from a
distribution's `BucketPolicy`. **S3 permits exactly one bucket policy per
bucket**, so two distributions fronting one store would each write that single
policy and silently unpick the other's grant: green deploy, 404s afterwards.
Making this one function's return a three-way choice is what keeps "both" from
being expressible.

The polarity is the useful part. Provisioning a store and serving it are
separate; before this, serving happened only as a side car to a host-UI bundle,
so a platform whose UI shipped from its own stack provisioned stores that
nothing could read.
*/
let servingFor = (~hasHostUiBundle: bool, ~declaredBucketCount: int): serving =>
  switch (hasHostUiBundle, declaredBucketCount) {
  | (_, 0) => NoStores
  | (true, _) => HostShell
  | (false, _) => PlatformOwned
  }

/**
Does the platform provision what the plugin's fields declare?

The split-stack ordering hazard, stated as a set difference: the platform
deploys before the plugin and cannot read its schemas, so its capability list is
written by hand and can simply be wrong. `required` comes from
`pluginStructure.requiredStores`; `provisioned` from the platform's exported
`objectStores` keys. Both are qualified `{plugin}.{store}`.

**Three outcomes, not two.** A platform provisioning nothing has not adopted
capability provisioning; failing it would break deployments that work today. A
platform provisioning *some* stores but not this one has adopted it and has a
missing or misspelled entry. Collapsing those two into one verdict forces a
choice between breaking the first group and not helping the second.

Worth being strict about because every symptom is silent: the upload input finds
no per-store endpoint, falls back to the legacy single service, and writes to
whatever bucket that serves — a 2xx, a plausible ref, and the wrong destination.
*/
let coverageFor = (~required: array<string>, ~provisioned: array<string>): coverage => {
  let missing = required->Array.filter(r => !(provisioned->Array.includes(r)))
  switch (missing, provisioned) {
  | ([], _) => Covered
  | (missing, []) => NotAdopted(missing)
  | (missing, provisioned) => Missing({missing, provisioned})
  }
}
