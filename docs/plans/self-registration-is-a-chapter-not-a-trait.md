# Plan: self-registration is a chapter, not a trait

**Date:** 2026-09-10
**Status:** Not started, and **not ready to step in full** — two gaps below have to close first. Filed
now because the shape is settled and because the two blockers are cheap to name and expensive to
discover late.
**Repos:** `reventless-core` only.
**Blocks on:** [identity-is-a-capability-not-a-cognito-handle.md](./identity-is-a-capability-not-a-cognito-handle.md)
(hard — nothing here works without `createPrincipal`) ·
[trait-contact-verification.md](./trait-contact-verification.md) Phase A (soft — this is the trait's
second purpose, and building it before the trait has one working host repeats the mistake that plan's
Phase A exists to avoid).

**Goal.** A person with no account proves control of an address and ends up with a principal, on both
platforms, with the admission rules as event-sourced domain state rather than a deploy-time constant.

**Non-goal.** A user manager. Roles, organisations and permission models are a different and much
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
organisation inside one deployment. A config key cannot express that at all.

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

## Key the policy by scope from the first commit

**The cheapest item here and the most expensive to retrofit.** Today there is one admission policy per
deployment. The moment a per-organisation policy is wanted — one org allowing any `@acme.com` address,
another invitation-only, both in one deployment — a singleton `RegistrationPolicy` means migrating a
component that already has live events.

Ship it **keyed by a scope**, with this tier using one well-known scope value. A later per-organisation
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
consumer account's verified email is reasonable; trusting a self-hosted IdP an organisation administers
is a judgement about that organisation. That is a fourth knob and it belongs beside the other three —
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

## Two blockers before this can be stepped in full

1. **The mode set is decomposed from requirements nobody here has stated.** The seven named modes are
   the common ones in the market, not ones this repo has been asked for, and the three-knob claim is
   argued from them rather than measured. The *decomposition* is the durable part; which modes are
   worth building is not decided. **Get one real requirement before building past `Closed` / `Open`.**
2. **The UI half is uninvestigated** — what a registration form is, what an unauthenticated route does,
   and what the shell does with a half-completed session. None of it is designed, and it is the half a
   user actually touches.

## Verification

- Duplicate registration is indistinguishable from a fresh one to an anonymous caller, and the existing
  account receives the different message. This is the security test.
- A policy change racing a registration is caught by the append condition rather than slipping through.
- An abandoned registration expires and releases its claim tag; the address is registrable again.
- `Closed` refuses at `decide`, not only in the client.
- The whole flow runs locally end to end with the log transport and no AWS.
- Full build warning-free, whole suite green.

## Honesty ledger

- **Read off code:** `Platform_Stack.res`'s `preventUserExistenceErrors: ENABLED` on both pool paths;
  the messaging capability's config rationale, quoted; the local log transport's behaviour; and the
  capability-layer facts recorded in the identity plan.
- **Design proposal, not validated:** the mode table, the three-knob decomposition, the three layers,
  and every claim about what a later per-organisation layer will want. The scope-keying and claim-tag
  instructions are cheap insurance argued from that unvalidated shape — they are worth taking anyway,
  because both are single fields now and migrations later.
- **Not investigated:** the UI half; GDPR erasure of a registration that never completed; whether the
  AppSync Events API's auth config tolerates an unauthenticated mutation on the same API; and what the
  local platform does about two processes writing the user store at once.
