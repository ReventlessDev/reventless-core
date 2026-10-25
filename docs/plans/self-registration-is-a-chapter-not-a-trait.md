# Plan: self-registration is a chapter, not a trait

**Date:** 2026-09-10, revised 2026-09-11
**Status:** ✅ **Built on the local platform.** 2026-10-24: one role — `Closed` / `Open` with
an optional end, the address claim, verify-then-create, the oracle-safe answers, and the throttle's
two layers — in a new plugin the local root hosts and the AWS root does not (*As built*, below).
**2026-10-25: admission is per role** — self-service, by invitation, or provisioned — declared
in code, with whether a self-service role is open kept live per role
([Admission per role](#admission-per-role--planned-2026-10-24), steps
[A1](#a1-the-strategy-and-the-declared-table) to [A7](#a7-the-example), built in commit
`9c37bf50f`; [what landed](#as-built-2026-10-25)). **Still open:** the AWS door (deferred by the
identity plan's
[Step 3b](identity-is-a-capability-not-a-cognito-handle.md#step-3b--the-aws-door-decided-2026-09-11-deferred)),
which must enforce the same limit before any public sign-up, and with it the admission check and the
shell's configuration on AWS. **2026-10-25: the chapter is reusable by other apps**, as the
package `@reventlessdev/reventless-registration` an app's plugin lists
([Making the chapter reusable](#making-the-chapter-reusable--planned-2026-10-25), steps
[R1](#r1-a-plugin-lists-slices-an-installed-package-provides) to [R4](#r4-the-chapter-is-published-as-a-library-of-slices),
all built). **Next:** an invitation door, now that
[a door is handed its caller](done/a-door-is-handed-its-caller.md) (done 2026-10-25). Filed 2026-09-10; revised
2026-09-11 when the AWS door was deferred and the first requirement arrived.
**Repos:** `reventless-core` only.
**Blocks on:** [identity-is-a-capability-not-a-cognito-handle.md](./identity-is-a-capability-not-a-cognito-handle.md)
(hard — nothing here works without `createPrincipal`) ·
[trait-contact-verification.md](./trait-contact-verification.md) Phase A (soft — this is the trait's
second purpose, and building it before the trait has one working host repeats the mistake that plan's
Phase A exists to avoid).

**Goal.** A person with no account proves control of an address and ends up with a principal, on both
platforms, with the admission rules as event-sourced domain state rather than a deploy-time constant.

**Non-goal.** A user manager. Roles, organizations and permission models are a different and much
larger thing; this deliberately builds the smallest slice-set that a later one can grow around.

---

## Why it is not a trait

Every trait grafts onto a host. **Self-registration has no host** — it creates the subject the rest of
the system is about. A bundle whose centre of gravity is outside the event log is not a graft, and its
policy is precisely the part that would not survive a host swap. So this is a chapter: `Register`,
`SubmitProof`, the claim tags, and a `RegistrationPolicy` component.

That the trait stays untouched by everything in this plan is the evidence the boundary was drawn
correctly — it was drawn before the admission question was asked, and it held.

## Verify-then-create, and the deciding argument is uniqueness

Two orderings are possible and the wrong one is a permanent tax.

**A. Create-then-confirm** — registration creates the principal unconfirmed, the proof confirms it.
This is what Cognito's own `SignUp` assumes.

**B. Verify-then-create** — registration records a *pending registration* in the trait's own state,
tagged on the address; the proof creates the principal. **Take B.**

Under A, "this email is taken" is enforced by the provider — `UsernameExistsException` on Cognito,
something else elsewhere, and nothing at all on a YAML file. The rule deciding who owns an address
would live in the one place the design is trying to make swappable. Under B it is a **DCB claim tag**:
one reader, one mechanism, identical on both platforms, testable in-memory, provider-independent.

B also removes an entire state. There is no orphan unconfirmed principal to reap, so the capability
needs `createPrincipal` and not `confirmPrincipal`, and its surface stays small — which is what makes it
swappable.

Two consequences to accept rather than work around:

- **The credential is captured later.** The proof link lands on a set-a-password step, and that step
  calls `createPrincipal`. One more round trip than typing a password on the signup form, and the flow
  most consumer products have converged on. It also means a password is never held for an address
  nobody has proven they control.
- **The claim must expire.** A pending registration holds the address, so an abandoned one must release
  it — a `RegistrationExpired` event releasing the claim tag.

**Then turn the provider's own verification off.** If the domain owns the competency the provider must
not also own it: two verifiers means two sources of truth about one fact, and the provider's is
invisible to every read model, absent locally, and different on the next provider.

**And keep the provider's own sign-up entrance shut.** On Cognito that is `platform:signUpMode`, and on
every pool this chapter serves it stays `adminOnly`. Opening it does not help this flow —
`createPrincipal` is an administrator's call, which an admin-only pool accepts — and it reopens ordering
A beside it: Cognito's public `SignUp` needs only the app client id, which ships in the page, so anyone
could create a principal with no claim tag and no proof. **The pool setting is not a way to open
registration, even briefly.** The policy below is.

## Admission is three orthogonal knobs, not an enum

Every mode anyone asks for decomposes into three independent questions: **who may issue a challenge**,
**what must be true of the subject**, and **what a settled proof does**.

| Named mode | Who may issue | Predicate on the subject | What a settled proof does |
|---|---|---|---|
| **Closed** | nobody | — | — |
| **Open** | anonymous | none | create the principal, default groups |
| **Domain-restricted** | anonymous | address matches an allowlist | create the principal, default groups |
| **Join-by-code** | anonymous | a valid, unexpired shared code | create the principal, *the code's* groups |
| **Invitation-only** | an authenticated inviter holding a role | none | create the principal, *the invitation's* groups |
| **Open + approval** | anonymous | none | record a request; a human decision creates the principal |
| **Waitlist** | anonymous | none | as approval, released in batches |

**Invitation-only is not a different mechanism.** Same challenge ledger, same expiry, same claim tag,
same proof door — `ContactVerification` with `purpose: Invitation`. The only differences are who issued
the challenge and whether a payload rode along. One machine, two entrances.

An enum is the right surface for an admin and the wrong one for the model. **Invitation-only *plus* an
allowlist** — colleagues self-serve, outsiders need an invite — is an ordinary B2B requirement, and it
is two knobs rather than a seventh mode. A six-arm variant has to be reopened for it; a decomposition
does not. So: an admin picks a named mode, the state stores the three knobs, and unusual combinations
are expressible without a migration.

## Where each knob lives — and only one layer is config

The instinct is Pulumi config beside the messaging keys. That instinct is wrong, and the repo's own
reasoning says why: messaging keys are configuration because *"a staging stack should not mail
customers, and nothing about the shop it deploys says so"* and because a verified sender is a
per-account fact. Config is for **what a repository cannot know and an environment fixes**. Admission is
neither — it is a product decision, changed by an admin without a deploy, and eventually different per
organization inside one deployment. A config key cannot express that at all.

| Layer | Carries | Changed by | Why there |
|---|---|---|---|
| **Compile time** — is the chapter grafted | whether the anonymous door exists at all | a deploy | An unauthenticated mutation that always refuses is still an attack surface. A deployment that will never self-register does not graft the chapter, and no runtime state can turn it on. This is the **hard cap**, it is free, and the mechanism already exists |
| **Runtime domain state** — a `RegistrationPolicy` component | the three knobs, with commands, events and a read model | an admin, through an ordinary authorized command | It is policy, it is audited like every other decision, and it is consulted in `decide` inside the consistency boundary |
| **Deploy config** | the safe default at first boot | a deployer | An event-sourced setting has no value before anyone sets one, and that default must be `Closed` — never `Open` |

**A ceiling is deliberately left out.** "This deployment may never exceed invitation-only, whatever the
state says" is justified by blast radius — without it, a compromised admin account is open
registration. That matters for a regulated estate and is noise for a shop, and the hard cap covers the
common case. One config key is cheap to add when a deployment asks. Recorded so it is a decision rather
than an omission.

### Opening a `Closed` deployment for a while

A deployer who ships `Closed` and wants to exercise registration on their own deployment flips the
**policy**, not the deployment: one authorized command opens it, another closes it. No redeploy, no
source edit, and both land in the log with who did it and when. It needs no admin UI — the command is
the whole mechanism, and any authorized client can send it.

**Proposed: give `Open` an optional end.** A test window someone forgets to close is open registration.
An `openUntil` on the issue knob, checked lazily in `decide` against the time the command carries — read
at the edge, as the verification trait's `presentedAt` already is — closes the window with no scheduler
and no closing event. Past its end, `Open` refuses exactly as `Closed` does. It bounds an existing mode
rather than adding one, so the decomposition is not reopened.

## Key the policy by scope from the first commit

**The cheapest item here and the most expensive to retrofit.** Today there is one admission policy per
deployment. The moment a per-organization policy is wanted — one org allowing any `@acme.com` address,
another invitation-only, both in one deployment — a singleton `RegistrationPolicy` means migrating a
component that already has live events.

Ship it **keyed by a scope**, with this tier using one well-known scope value. A later per-organization
layer supplies different keys and nothing moves. The cost today is a single field on the component's
identity and the tag it is written under.

The same instruction applies to the **claim tag**: make its key a policy hole the host fills rather than
a spelling the chapter invents, so a later user-management layer claiming addresses under its own key
does not find uniqueness split between two mechanisms that each believe they own it.

## Enforced in `decide`, and the refusals are a security decision

The mode is consulted in the registration slice's `decide`, in the same transaction and against the
same DCB boundary as the claim tag. A policy change arriving concurrently cannot slip through, because
the append condition detects the conflict. Anything checked outside that boundary can be raced. The
client also filters — a login page must not offer a registration form under `Closed` — but that is UX
only; the gate is server-side.

**And the refusal vocabulary is a security decision, not a UX one.** "Registration is not open here" is
safe to tell an anonymous caller. "That address is already registered" is not — it turns the door into
an account-existence oracle. Under **every** mode, a closed answer and a taken answer must be
indistinguishable to an anonymous caller. The honest response to a duplicate registration is the same
"check your inbox" the successful case gives, with a *different message actually sent* — to the existing
account, saying someone tried to register with their address. `Platform_Stack.res` already sets
`preventUserExistenceErrors: ENABLED` on both pool paths; a domain-owned flow has to **reproduce** that
property rather than inherit it.

## Two paths that skip the challenge, and one knob that is not a mode

**Federated sign-in.** The upstream provider has already proved control of the address, so no challenge
should be issued. In trait terms this is not a special case — it is the **stand-down**, the same arm as
geocoding's map picker: a verdict arrived through another door, so spend no capability call. It carries
one policy question of its own, and not a small one: **whose assertions count as proof.** Trusting a
consumer account's verified email is reasonable; trusting a self-hosted IdP an organization administers
is a judgement about that organization. That is a fourth knob and it belongs beside the other three —
the capability federates, the domain decides what federation proves.

**Magic-link sign-in.** Once the trait exists this is nearly free: a login is a repeat verification with
a `SignIn` purpose, settling into a session rather than a principal. Worth knowing *before* the ordering
above is implemented, because it argues against hard-coding password capture into the proof step — the
proof step should settle a challenge and let the chapter decide what that entitles.

**Terms and consent is not an eighth mode.** Whether registration captures acceptance of terms, a
privacy-policy version or a marketing opt-in is orthogonal to admission, is a GDPR artifact rather than
an access control, and belongs on the registration command as required fields the chapter declares.

## Both platforms

| | AWS | Local |
|---|---|---|
| Send the token | ✅ SES, plus a `log` transport chosen by config | ✅ the log transport writes the message out |
| Create a principal | ⚠️ needs the capability's Cognito provider | ⚠️ needs the capability's local provider |
| Throttle the anonymous door | ⚠️ WAF / AppSync throttling — see below | ❌ nothing exists |
| The anonymous door itself | ❌ **deferred 2026-09-11** — AppSync has no anonymous auth mode, and `AllowAnonymous` refuses the deploy. When built: a separate narrow door, not a third auth type on the platform API | ✅ `AllowAnonymous` is honored — the resolvers call `Authorization.isAllowed` |

**So this is built and proven locally first.** The door's shape is decided in the identity plan's
Step 3b: a door of its own, so the platform API keeps two auth types and the risk sits in one place. The
option that needs no door — the browser calling the provider's own sign-up — is rejected rather than
deferred, because it is ordering A.

**The local story is unusually good and worth protecting.** With the log transport a developer
registers, reads the token out of the platform log, and completes the flow — no mailbox, no external
service, no AWS. That falls out of the capability model already being in place for `Messaging`, and it
is the reason to keep the flow honest locally rather than AWS-first.

## The gap that must close before this ships anywhere public

**Unauthenticated request throttling has no home in the model.** Attempt counts per challenge are
ordinary event-sourced state and belong in `decide`. "At most three registrations per IP per hour" is a
transport concern: WAF or AppSync throttling on AWS, nothing at all locally.

For a private deployment that is a README caveat. **For any publicly reachable deployment running
`Open` it is a deploy requirement of this plan**, not follow-up work: an anonymous door that sends real
mail to an attacker-chosen address is an abuse target, and the cost rises from sender reputation to
money per request the moment an SMS channel exists. Whichever deployment first opens this door
publicly must land the throttle in the same increment.

**Built 2026-10-24, in the two layers this section separates.** The transport half is
`AnonymousRequestLimit`: deployment configuration, `requests/seconds`, ten an hour by default, applied
to every door whose rule is `AllowAnonymous` per source address, and answered with a `Throttled`
rejection (a platform code, cause `INFRASTRUCTURE`). The local platform enforces it on its GraphQL
doors; the AWS door will read the same setting, and must, before any public `Open`. The domain half is
a cooldown in the ledger: a registered address is told someone tried at most once an hour, counted
from the recorded notice, so it survives a replay. Verified live: with the limit at two, the third
anonymous sign-up from one address answered `Throttled`, and a signed-in command was not counted.

**A test window counts.** An `Open` with an end bounds the exposure; it does not remove it. `Closed`
refuses in `decide` before anything is sent, so the mail-abuse cost this throttle exists for is incurred
only while the policy is open — which is exactly when a deployer testing on a public URL has opened it.

## Two blockers before this can be stepped in full

1. **The mode set is decomposed from requirements nobody here has stated.** The seven named modes are
   the common ones in the market, not ones this repo has been asked for, and the three-knob claim is
   argued from them rather than measured. The *decomposition* is the durable part; which modes are
   worth building is not decided. **Get one real requirement before building past `Closed` / `Open`.**
   *One has since been stated (2026-09-11):* a deployer opening their own `Closed` deployment briefly
   to exercise the flow. It needs nothing past `Closed` / `Open` — it argues for a bound on `Open`, not
   for another mode.
2. **The UI half is uninvestigated** — what a registration form is, what an unauthenticated route does,
   and what the shell does with a half-completed session. None of it is designed, and it is the half a
   user actually touches.

## As built 2026-10-24

**Where it lives.** `examples/online-shop-hybrid/registration`, a plugin of its own, private, hosted by
the local root only. *Since 2026-10-25 the slices live in the package
`reventless/registration`, which that plugin lists — see
[R4](#r4-the-chapter-is-published-as-a-library-of-slices).* Its doors admit anonymous callers, and the hybrid example deploys to AWS on every
push, where such a field is refused; a plugin the AWS root does not host keeps that deploy green.

**What it is.** One chapter, `Registration/`:

| Component | Kind | What it does |
|---|---|---|
| `RegistrationPolicy` | StateChange, `AllowRoles([Admin])` | `OpenRegistration({scopeId, until?})` / `CloseRegistration`. Nothing recorded is closed. Keyed by scope from the first event, with one scope, `default`, today |
| `Registrations` | StateChange, every command `@noApi` | The ledger, partitioned by `ContactAddressId` — the claim tag `contactAddress`. Reads the policy by scope as its own clause, so a policy change racing a registration fails the append |
| `SignUp` | Inbound, `AllowAnonymous` | Stamps the arrival time at the edge, so a caller cannot choose the instant an open window is measured against |
| `SendRegistrationChallenge` | Outbound, `Messaging` | Sends the secret and records its hash; to an address already registered, sends a notice instead |
| `CompleteRegistration` | Inbound, `AllowAnonymous`, `Stash` | Takes the proof and the password, both `@sensitive`. Hashes the proof, puts the password in the stash under that hash, relays only the hash |
| `CreateRegisteredPrincipal` | Outbound, `Stash` + `IdentityProvider` | On an accepted proof, takes the password and creates the account in the `Shopper` group |

**The password never reaches the log.** An inbound translation is now async and handed the platform's
capabilities, and keeps `@sensitive` fields out of its audit row; that still does not let the door see
whether a proof was valid, which only a `decide` can. The stash closes that: a value held for minutes outside the
log and handed over once, in memory on the local platform and not yet provisioned on AWS. A refused
proof leaves the password to expire. A provider outage puts it back for the retry.

**Every arm of the ledger answers `Ok`.** A closed policy and a pending registration record nothing; a
registered address records the attempt, and the outbound slice tells the address someone tried. The
caller is answered the same in all four cases — verified live, below.

**Expiry is lazy.** A registration nobody finished stops holding the address after the challenge's
24-hour window; the next `Register` records `RegistrationExpired` and a fresh `RegistrationRequested`.
No scheduler.

**The challenge rules are a copy.** A plugin may not import another's source, so `ContactVerification`
and its guards are copied from the ordering plugin, with a note saying so. Registration exercises the
arm the first consumer cannot — `hostContact = None` — which is what the trait's extraction —
[Phase C](trait-contact-verification.md#phase-c--extract-writing-the-procedure-down-as-you-go) of the
verification plan — needs both copies for.

**Verified on a running local platform**, from a scratch directory so the real accounts file was not
touched:

- A sign-up while closed and one while open both answer `CommandAccepted`; only the open one sends
  anything.
- An anonymous caller opening registration is refused (`Forbidden`, cause `ACCESS`).
- The logged message carries the 32-character code; a wrong proof is recorded as `ProofMismatch`; the
  right one settles, and the account appears in the accounts file in `Shopper` with a minted `u_` id.
- Signing in with the chosen password succeeds and the token carries that id; a wrong password is 401.
- A second sign-up for the same address answers exactly as the first, and the address receives
  "Someone tried to register with your address".
- The completion door's audit rows hold `"proof":"[withheld]","password":"[withheld]"`; the password
  appears nowhere in the platform's log.

**Not here, and why.** The AWS door and the throttle, as above. A password the provider refuses after
the proof settled leaves the registration verified with no account, since the proof cannot be spent
twice; the door checks the length the pool requires so the common case cannot reach that. The
"someone tried" notice is held to one an hour per address since the throttle landed — see
[the throttle section](#the-gap-that-must-close-before-this-ships-anywhere-public).

## Admission per role — planned 2026-10-24

### In plain words

What is built answers one question for everybody: registration is open or closed, and an account
always lands in the `Shopper` group. A deployment wants a different answer per role. Shoppers sign
themselves up; staff are made by hand; and a deployment may want a role joined only when someone
already inside invites. So each role gets an **admission strategy**, declared in code, and whether a
self-service role is open *right now* stays live domain state, per role. This repository builds
self-service and provisioned in full. Invitation it declares and checks: a plugin that provides an
invite door marks it, and a deployment that declares a role by invitation without such a door is
refused rather than left with a declaration nothing honors.

This is the decomposition [Admission is three orthogonal knobs](#admission-is-three-orthogonal-knobs-not-an-enum)
argued for, meeting its first real requirement: *who may start* varies by role (anyone, or a
signed-in inviter), and *what a settled proof grants* is the role's group.

| Strategy | Who starts it | The account lands in | Door |
|---|---|---|---|
| `SelfService` | anyone, not signed in | the role's group | `SignUp(email, role)` |
| `Invitation({by})` | a signed-in caller holding one of the roles in `by` | the invited role's group | provided and marked by a plugin of its own; it completes through the same completion door |
| `Provisioned` | an administrator, outside this chapter | — | none: the accounts file locally, `provision-accounts` on AWS |

### Decisions

- **Declared in code, not in a UI hints file.** A switch in the presentation file was considered and
  rejected: it would put a security setting in a file documented as presentation only, and it
  cannot say different things for different roles. The declaration is the hard cap: a role that is
  not `SelfService` has no door for visitors at all, and one that is not `Invitation` has no invite.
- **Open and closed is per role, and live.** The policy's scope becomes the role, replacing the one
  `default` scope. A role declared `SelfService` is open until an administrator closes it — the
  declaration is the deployer's opt-in, so requiring a second command to make it do anything would
  be a trap. Closing and reopening needs no redeploy, on either platform.
- **One completion door.** A sign-up's code and an invitation's code look the same at the door: an
  address, a code, a password. The ledger knows which roles each registration grants.
- **The declaration may name a door this repository does not ship.** `Invitation` is in the type so
  that one table serves the deploy check, an authoring tool and whichever plugin provides the door;
  what this repository guarantees is that the declaration is never silently unmet.
- **The shell is told, not configured.** The platform writes the doors and the self-service roles
  into the shell's `config.json` from the plugin structure, so nobody names a mutation by hand, and
  visitors read which self-service roles are open through a public query.

### Steps

Numbered A1 to A7.

#### A1: the strategy and the declared table

`Reventless.Admission` in spec: `type strategy = SelfService | Invitation({by: array<string>}) |
Provisioned`, and a table keyed by **group** name — accounts are created in groups, and a plugin's
roles map to groups at the platform root. The app declares it as `src/Admission.res` beside
`Roles.res`; an authoring tool may write it, as it may write `Roles.res`.

**Exit:** the type, its decoder, and a test that an unknown group or strategy refuses rather than
defaults.

#### A2: the policy per role

`OpenRegistration` / `CloseRegistration` take a role instead of a scope. A role declared
`SelfService` reads as open while nothing is recorded; any other role is never open.

**Exit:** GWT for a declared role open by default, closed by command, reopened; and a role not
declared self-service refusing quietly whatever the policy says.

#### A3: sign-up names the role

`SignUp` takes the role, and a registration records the roles it grants as a set — one for a
sign-up, so that a door granting several at once records them all and the principal is created in
all of their groups. A role that is not self-service, or not open, records nothing — answered
exactly as a closed policy is. `CreateRegisteredPrincipal` grants the registration's roles' groups
instead of `Shopper`.

**Exit:** GWT per strategy; the live walk of *As built* repeated with two roles.

#### A4: marked doors, written into the shell's config

Each door's spec marks its part — start, complete, and invite where a plugin provides one — and the
platform collects them from the plugin structure into `config.json` as
`selfRegistration: {start, complete, roles}`, `roles` being the self-service groups. Written on both
platforms; on AWS only once the door exists. The invite marker is also what
[A6](#a6-checks-at-start-and-deploy) looks for before accepting a role declared by invitation.

**Exit:** the local platform serves the key with no line in the root; a test on the collection.

#### A5: a public read of the open roles

An anonymous query answering which self-service roles are open now. It tells a visitor only what
[Enforced in decide](#enforced-in-decide-and-the-refusals-are-a-security-decision) already counts
as safe — that registration is or is not open here — and nothing about any address.

**Exit:** the query answers per role, and the throttle counts it like any anonymous door.

#### A6: checks at start and deploy

Refused, naming the role: a strategy for a group no role maps to; `SelfService` for an elevated
group (the administrator group, or one in `elevatedGroups`); `SelfService` or `Invitation` without
messaging and an identity provider provisioned; `Invitation` when no plugin in the deployment marks
an invite door ("Merchandiser is by invitation, but nothing in this deployment provides
invitations"); and, on AWS, `SelfService` until the door exists.

**Exit:** a test per refusal.

#### A7: the example

The hybrid shop declares `Shopper` self-service and `Merchandiser`, `Fulfilment` and `Admin`
provisioned — staff are made from the accounts file locally and by `provision-accounts` on AWS; the
local root drops any hand-written registration key.

**Exit:** the live walk: a shopper signs up, a merchandiser address cannot sign up and is answered
exactly as a closed role is, `Fulfilment` cannot be declared self-service, and closing `Shopper`
hides the link.

### As built 2026-10-25

Commit `9c37bf50f`, local platform only. What each step became:

| Step | Where | What landed |
|---|---|---|
| [A1](#a1-the-strategy-and-the-declared-table) | `reventless/spec` `Admission` | `strategy<'role>`, `declare` over the plugin's own `Roles.t`, `validate`, the JSON and structure forms (`toDefs`/`fromDefs`), an unknown strategy refused |
| [A2](#a2-the-policy-per-role) | the plugin's `RegistrationPolicy` | keyed by role; a self-service role reads as open while nothing is recorded |
| [A3](#a3-sign-up-names-the-role) | `SignUp`, `Registrations`, `CreateRegisteredPrincipal` | `Register` names one role; the ledger's events record `roles` as a set; the principal is created in every role's group. **A command that grants several roles at once does not exist yet** — see [R3](#r3-the-ledger-takes-an-invitation-a-reissued-code-and-a-withdrawal) |
| [A4](#a4-marked-doors-written-into-the-shells-config) | `let admissionDoor` on a door's spec; `Platform_SelfRegistration`; the local `Platform` | the generator collects marked doors into the structure; the platform writes `selfRegistration: {start, complete, roles}` into `config.json` once every structure has landed |
| [A5](#a5-a-public-read-of-the-open-roles) | `RegistrationWindows` | a view of which roles are open now; anonymous read doors throttled like the writes |
| [A6](#a6-checks-at-start-and-deploy) | `reventless/spec` `AdmissionCheck`, called by the local `Platform` | refused at start, naming the role: an elevated group self-service; no start-and-complete door; no anonymous door on this platform; no messaging or identity provider; a role by invitation when no structure marks an invite door. **Not called on AWS**, which today would refuse every self-service role since it admits no anonymous caller |
| [A7](#a7-the-example) | the hybrid shop's `Admission.res` | shoppers self-service, staff provisioned; `Roles.t` grew to the four roles |

Pinned by `AdmissionTest`, `Platform_SelfRegistrationTest`, and the plugin's GWTs. The live walk
of [A7](#a7-the-example) is not recorded here.

**What the slices read, and why it matters next.** The sign-up translation reads `Admission.table`
to pick the default role, and the principal creator reads `Role.groupOf`. Both are the plugin's own
modules, which is right for a chapter copied into one app and is exactly what stops the chapter
being installed as a package: see [R2](#r2-a-packaged-slice-reads-the-apps-declaration).

## Making the chapter reusable — planned 2026-10-25

### In plain words

The registration chapter exists once, inside the hybrid shop's plugin, with that shop's roles and
that shop's admission table compiled in. Every other app that wants a self-service role copies it,
as the trait plan said hosts would until the trait is extracted
([Phase C](trait-contact-verification.md#phase-c--extract-writing-the-procedure-down-as-you-go)).
A plugin cannot be published as a package, because a plugin is per app: it carries the app's roles.
What can be published is its **slices**. So the road to reuse is: let a plugin list slices from an
installed package, let such a slice read the app's declaration without importing the app's module,
and publish the chapter as a library of slices the hybrid shop's plugin lists instead of carrying.

Two facts shape the steps. **A door relays only to a slice of its own plugin**: a published command
goes to the plugin's topic on both platforms, so a door that invites has to be a slice of the same
plugin as the ledger it writes, which is why the ledger's invitation arms are open and `@noApi` and
the door that reaches them may come from another package. And **the ledger's arms are generally
useful** whichever door reaches them: a reissued code serves a sign-up as much as an invitation, and
a withdrawal is an administrator cancelling a pending registration.

### Steps

Numbered R1 to R4. **R** stands for *reusable*.

#### R1: a plugin lists slices an installed package provides

The generator scans `src/` for slices and writes the composition. It gains a way for a plugin to
name slices from a package its `rescript.json` depends on: a list beside the discovered ones, read
off the compiled modules so the compiler checks them, in the generated `Plugin.res` and in the
structure, with the chapter of each recorded as the plugin's.

**Exit:** a test plugin lists one packaged slice; its structure and its GraphQL API show it as the
plugin's own; `generate` is byte-identical for a plugin that lists none.

**Built 2026-10-25.** `src/plugin.json` lists `slicesFrom: [{package, with?}]`. The generator
finds the package in the nearest `node_modules`, scans its `src/` as it scans the plugin's, and
aliases every module it found at the top of `Plugin.res`
(`module SignUp = RegistrationSlices.SignUp`), so the rest of the composition is generated from
bare names exactly as for the plugin's own files and the compiler checks each alias. Everything the
generator reads off source (`targetName`, `@@reventless.async`, `@@reventless.systemCallable`,
`admissionDoor`, identities) is read from the package, and the chapter is the folder the package
files the slice under. A body opening `module Make = (` is applied to the module `with` names, the
seam [R2](#r2-a-packaged-slice-reads-the-apps-declaration) uses. Refused, naming the file: a package
not installed, one with no namespace written out, one providing anything but slices, one providing
nothing, a functor body with no `with`, and a stem the plugin also uses. Pinned by
`PackagedSlicesTest` on a fixture plugin and package; regenerating every plugin in the repository
changed no file. The structure-and-API half of the exit is carried by
[R4](#r4-the-chapter-is-published-as-a-library-of-slices), where the hybrid shop composes a real
package: an alias composes a slice through the same factory call as a file of the plugin's own, so
there is no second path for the structure to differ on.

#### R2: a packaged slice reads the app's declaration

A packaged `SignUp` cannot import the app's `Admission`. Two shapes: the slices are functors over a
small module the app supplies, with its `Roles.t` and its table, so a misspelled role stays a compile
error; or the platform hands the table to its slices at construction, read off the structure. Decide
here; *recommendation:* the functor, because the declaration was designed to be checked by the
compiler, and the structure already carries the table for the platform's own reads.

**Exit:** the registration slices built with the chosen shape; the hybrid shop's plugin supplies its
roles and table and nothing else of its own to them.

**Built 2026-10-25, with [R4](#r4-the-chapter-is-published-as-a-library-of-slices), in one
commit:** a functor body only compiles once something applies it, and only a packaged one is applied
([R1](#r1-a-plugin-lists-slices-an-installed-package-provides)). The functor was taken. Three bodies
read the table, and each is now `module Make = (App: Reventless.Admission.Declaration) => {…}`:
`RegistrationPolicy_Decision`, `Registrations_Decision` and `SignUp_Translation`. The rest of each
file stays outside the functor. `Declaration` is `{let table: Admission.t}`, which a plugin's
`src/Admission.res` satisfies as written, so the shop's table is still checked against its
`Roles.t` by the compiler. The policy's own rule, `AllowRoles([Admin])`, names the framework's
administrator through a `Roles` module declared inside the spec, so the package has no top-level
`Roles` beside the app's.

#### R3: the ledger takes an invitation, a reissued code and a withdrawal

`Registrations` gains three `@noApi` commands, reachable only through a door: `Invite({email, roles,
invitedBy, requestedAt})`, which claims the address and records who invited and as what, with the set
of roles [A3](#a3-sign-up-names-the-role) left room for; `ReissueChallenge`, which voids the current
code and records a new one; and `Withdraw`, which releases the address. The events say which arm
produced them, so a sender can word an invitation differently from a sign-up. Whether an invitation's
window is longer than a sign-up's is keyed by purpose in the challenge rules.

**Exit:** GWT per command; the completion door settles an invited registration into every invited
role's group with no change to itself; nothing in the hybrid shop reaches the three commands, since
it declares no role by invitation.

**Built 2026-10-25**, in the package. The commands are `Invite`, `ReissueRegistrationChallenge`
and `WithdrawRegistration` — the last two named in full beside `IssueRegistrationChallenge`, since
a bare `Withdraw` says nothing about what — and each records an event of its own:
`RegistrationInvited`, `RegistrationChallengeReissued`, `RegistrationWithdrawn`.

- **`Invite`** checks the app's table, not the policy: the policy says whether visitors may sign
  themselves up, and an invitation is not that. Every role must be declared `Invitation`, or the
  inviter is refused `NotByInvitation`, naming the role; an empty set is refused `NoRoleToGrant`.
  These are the ledger's first errors. Every arm a visitor reaches still answers `Ok`; an inviter
  is signed in and is owed the reason. Who may invite — the inviter's own roles against the table's
  `by` — is the door's to check, once
  [a door is handed its caller](done/a-door-is-handed-its-caller.md); the ledger records `invitedBy`. An
  address holding an account, or a claim that has not lapsed, is not invited. A visitor's sign-up
  cannot take over an invited address while the invitation holds.
- **`ReissueRegistrationChallenge`** voids the code and its spent attempts, and the sender mints
  and sends a new one. Only a code that went out is voided: a reissue while the first code is still
  on its way would leave the ledger holding whichever arrived first. It is held to the resend
  cooldown, so a door reaching it cannot flood an inbox.
- **`WithdrawRegistration`** releases a claim nobody has proved. A settled one is not withdrawn,
  because the account is already on its way.
- **The window is keyed by purpose**, in `RegistrationChallenge` beside the copied rules rather than
  in them, so the copy stays a copy: an invitation's code holds a week, a sign-up's a day. The
  sender words an invitation as one, and a reissued code as its claim was.

The scenarios run in the hybrid shop. Those its table can reach live in `Registrations_GWT`, where
an invitation is refused because the shop declares no role by invitation. The accepted invitations
run in `RegistrationsByInvitation_GWT`, over a table that admits staff by invitation: the same
slice under a different table. The completion door's several-roles case was already pinned by
`CreateRegisteredPrincipal_GWT`.

#### R4: the chapter is published as a library of slices

The registration slices move to a package of their own under `reventless/`, Apache 2.0, built with
[R2](#r2-a-packaged-slice-reads-the-apps-declaration)'s shape. The hybrid shop's plugin shrinks to
`Roles.res`, `Admission.res`, the copied challenge rules until the trait is extracted, and the list
[R1](#r1-a-plugin-lists-slices-an-installed-package-provides) reads. The example is the proof that
an app's registration plugin is a declaration plus a list.

**Exit:** the hybrid shop builds and its walk passes from the package; a second plugin in the test
suite lists the same slices with different roles.

**Built 2026-10-25** as `@reventlessdev/reventless-registration` (`reventless/registration`,
namespace `ReventlessRegistration`), with the files moved by `git mv` so their history follows them.
Two corrections to the step as written:

- **The copied challenge rules moved with the slices.** `ContactVerification` and its guards are
  read by the ledger and the challenge sender, and a package cannot read an app's module, so they
  live in the package until the trait's
  [Phase C](trait-contact-verification.md#phase-c--extract-writing-the-procedure-down-as-you-go)
  extracts them. The hybrid shop's plugin is `Roles.res`, `Admission.res`, `plugin.json`'s list,
  and what the tools generate from them.
- **The scenarios stay in the plugin**, as a trait's conformance suite stays in its hosts: they run
  against the shop's table, the lifecycle harvest finds them where it finds every plugin's, and the
  package ships no test code. The plugin compiles with `-open ReventlessRegistration`, so a scenario
  names a packaged slice by its bare name. A test of a functor body applies it itself; for a
  translation that needed a PPX change — the injected `FromSlice` now follows a module the test
  declares under the body's own name (`module SignUp_Translation =
  SignUp_Translation.Make(Admission)`) rather than naming the unapplied one.

Every scenario passes from the package (55), the capability manifest re-emits unchanged, and the
lifecycle model, the DCB scope golden and the GraphQL goldens do not move.

**Walked live from the package**, on an in-memory local platform run from a scratch directory with
its own accounts file and ports:

- The SDL shows the slices as the Registration plugin's own (`Registration_SignUp`,
  `Registration_CompleteRegistration`, `Registration_OpenRegistration`, …), and the shell's
  `config.json` carries `selfRegistration: {start: "Registration_SignUp", complete:
  "Registration_CompleteRegistration", roles: ["Shopper"]}`.
- A sign-up naming no role took the one self-service role, `Shopper`, and the log transport printed
  the code. A sign-up for `Merchandiser` answered `CommandAccepted` too, and recorded and sent
  nothing.
- A wrong proof was recorded as `ProofMismatch`; the right one settled, and the account appeared in
  the scratch accounts file in `Shopper` with a minted `u_` id. Signing in answered 200 with the
  chosen password and 401 with another; the password appears nowhere in the log.
- A second sign-up for the same address answered `CommandAccepted`, and the address got "Someone
  tried to register with your address".
- An administrator closed `Shopper`; `Registration_RegistrationWindows` showed it closed, and a
  sign-up then answered `CommandAccepted` and recorded nothing. Opening `Merchandiser` was refused
  `NotSelfService`; opening anything without the `Admin` role was refused `Forbidden`.

**The second plugin is not built:** no second app here needs registration, and a plugin made
only to list the slices would be an example nobody reads. What it would prove — that nothing in the
slices is the shop's — is carried instead by the package compiling with no app module in reach and by
`PackagedSlicesTest`, which composes a fixture package under a plugin of its own.

### Decisions

- The ledger's arms are open and reachable only through doors; the framework ships the sign-up and
  completion doors and no invite door. A door another package provides is a slice of the app's
  plugin, by [R1](#r1-a-plugin-lists-slices-an-installed-package-provides).
- A plugin stays per app. What is published is slices; the roles and the table never leave the app.

## Verification

- ✅ Duplicate registration is indistinguishable from a fresh one to an anonymous caller, and the
  existing account receives the different message. This is the security test.
- ✅ A policy change racing a registration is caught by the append condition rather than slipping
  through — pinned by the ledger's decision query in `Registrations_GWT`.
- ✅ An abandoned registration expires and releases its claim tag; the address is registrable again.
- ✅ `Closed` refuses at `decide`, not only in the client.
- ✅ The whole flow runs locally end to end with the log transport and no AWS.
- On AWS, once a door exists, the flow completes against a pool whose own sign-up is `adminOnly` —
  nothing here leans on the provider's self-service.
- ✅ The bound is taken: past its end, an `Open` window refuses exactly as `Closed` does, with no event
  recorded to close it.
- Full build warning-free, whole suite green.

## Honesty ledger

- **Read off code:** `Platform_Stack.res`'s `preventUserExistenceErrors: ENABLED` on both pool paths;
  the messaging capability's config rationale, quoted; the local log transport's behavior; and the
  capability-layer facts recorded in the identity plan. *Added 2026-09-11:* `provision-identity
  --sign-up-mode` applies only when the script **creates** a pool — an existing one is adopted unchanged
  — and a stack given a supplied pool ignores `platform:signUpMode`, so a supplied pool's sign-up
  setting cannot be flipped by any supported path.
- **Asserted from outside the repo:** that `AdminCreateUser` succeeds on a pool with
  `AllowAdminCreateUserOnly: true` — the flag's documented purpose, and what lets the pool stay shut
  while `createPrincipal` works. Confirm when the Cognito provider is built.
- **Design proposal, not validated:** the mode table, the three-knob decomposition, the three layers,
  the bounded `Open`, and every claim about what a later per-organization layer will want. The scope-keying and claim-tag
  instructions are cheap insurance argued from that unvalidated shape — they are worth taking anyway,
  because both are single fields now and migrations later.
- **Not investigated:** the UI half; GDPR erasure of a registration that never completed; whether the
  AppSync Events API's auth config tolerates an unauthenticated mutation on the same API; and what the
  local platform does about two processes writing the user store at once.
