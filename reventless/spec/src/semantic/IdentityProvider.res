/**
Making, grouping and unmaking principals, so the provider behind them is a
supplier rather than a call site.

The *administrative* half of identity only. Authentication — token issuance, JWT
verification, session handling — is `Auth_Adapter.Provider`'s, and stays there:
the two are read at different times over one provider, exactly as this and
`CapabilityNeed.t` are.

🚨 **Nothing here is a domain event's business.** `principal` is the provider's
own handle and must never reach an event log: a log full of one provider's ids
cannot be migrated to another, which would make the replaceability this
capability exists for a fiction. What the log holds is the domain's own opaque
user id; the mapping between the two lives in this capability's store.
*/
/** The provider's own handle for a principal. Opaque on purpose — a caller that
    can read structure out of it is a caller coupled to the provider. */
type principal = {providerId: string}

/** How a new principal proves it is them. A variant rather than a bare password
    so a provider offering only federated or passwordless enrolment can refuse
    the arm it does not implement instead of being handed a secret it will
    discard. */
type credential =
  | Password(string)
  /** Enrol with no secret held here: the principal sets one through the
        provider's own flow, or signs in federated. */
  | NoCredential

/**
Why an operation did not happen.

Three arms rather than two, and the split is the one geocoding taught: **a
provider outage is not a verdict.** `Unavailable` must be retried, because a
caller reaching `createPrincipal` has already recorded that the address was
proven and the person is entitled to an account. `Refused` is permanent and must
surface. Collapsing them either loses accounts to a transient blip or retries
forever against a password policy.
*/
type failure =
  /** The contact is already a principal. A modelled answer, not an exception —
        which is what a silent idempotent sign-up throws away. */
  | Conflict
  /** The provider is down or unreachable. The domain fact stands; retry. */
  | Unavailable(string)
  /** Permanently rejected — policy, password rules, a refused attribute. */
  | Refused(string)

/**
One thing a provider can be asked to do.

Published rather than fixed, because providers genuinely differ: one bound
read-only to a corporate directory can create nothing, and one with no group
model cannot be asked about groups. A caller reads this and degrades, instead of
discovering the gap as a `Refused` on a live registration.

**`setActiveRole` is deliberately absent.** Narrowing a caller's claims to the
role they chose happens when a token is *minted* — on Cognito, in a
pre-token-generation trigger. That is token issuance, which this capability's
non-goal hands to the auth seam. Admitting it here would grow the surface along
an axis that has nothing to do with whether the principal store is replaceable,
which is the one thing this type exists to protect.
*/
type operation =
  | CreatePrincipal
  | AddToGroup
  | RemoveFromGroup
  | DeletePrincipal

let operationToString = (operation: operation): string =>
  switch operation {
  | CreatePrincipal => "CreatePrincipal"
  | AddToGroup => "AddToGroup"
  | RemoveFromGroup => "RemoveFromGroup"
  | DeletePrincipal => "DeletePrincipal"
  }

/**
The port a caller reaches an identity provider through.

`operations` is the provisioned set this deployment's provider actually
supports, published rather than inferred. Build one through `make`, so a
provider cannot claim an operation and omit the function that performs it.
*/
type t = {
  createPrincipal: (
    ~contact: Messaging.recipient,
    ~credential: credential,
    ~groups: array<string>,
  ) => promise<result<principal, failure>>,
  addToGroup: (~principal: principal, ~group: string) => promise<result<unit, failure>>,
  removeFromGroup: (~principal: principal, ~group: string) => promise<result<unit, failure>>,
  deletePrincipal: (~principal: principal) => promise<result<unit, failure>>,
  operations: array<operation>,
}

let make = (
  ~createPrincipal,
  ~addToGroup,
  ~removeFromGroup,
  ~deletePrincipal,
  ~operations,
): t => {
  createPrincipal,
  addToGroup,
  removeFromGroup,
  deletePrincipal,
  operations,
}

let supports = (provider: t, ~operation: operation): bool =>
  provider.operations->Array.includes(operation)

/**
A provider that performs nothing, answering `Unavailable` on every operation
with an empty `operations`.

The two say different true things and both are needed. The empty list is what a
caller reads before offering a flow that cannot complete. The refusal stays
`Unavailable` rather than `Refused` because a caller that got this far is looking
at a deployment gap, not at a verdict on the person — and `Refused` would strand
someone who has already proven their address.
*/
let unavailable = (~reason: string): t =>
  make(
    ~createPrincipal=async (~contact as _, ~credential as _, ~groups as _) => Error(
      Unavailable(reason),
    ),
    ~addToGroup=async (~principal as _, ~group as _) => Error(Unavailable(reason)),
    ~removeFromGroup=async (~principal as _, ~group as _) => Error(Unavailable(reason)),
    ~deletePrincipal=async (~principal as _) => Error(Unavailable(reason)),
    ~operations=[],
  )
