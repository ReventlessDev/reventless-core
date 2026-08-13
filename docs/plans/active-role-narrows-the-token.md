# Plan: a caller holding several roles can act as one of them

**Status.** Steps 1, 2 and 2b **built 2026-08-13** on the local path (core
`61141ac78`, `6e8f06a22`) and verified against a running example. Steps 3–4
open.

**Sibling plans:**
- `docs/plans/curated-manifest-per-journey.md` — what each role *sees*. Independent
  of this one and buildable in either order; this plan decides what a role
  *may do*, which is the half that has to be right.
- `reventless-ui: docs/plans/shell-active-role-switch.md` — the control that asks
  for the narrowing this plan mints.

**Goal.** A user whose account holds several groups can act as one of them, and
every enforcement point in the system agrees with the choice.

**Non-goal.** Revocation. See §5 — this is a safety mechanism, and calling it
anything else would be a lie a reader could act on.

---

## §1 — Why the token, and not a request header

The cheap shape is a header: the client says "treat me as `Shopper`" and our own
enforcement intersects that with the token's groups. It reaches a great deal —
owner-scoped reads, `CommandGenerator_Callback`, the `QueryDb_Callback`
interceptor — and it is still wrong, because what it reaches is not everything
that runs.

`@authorize(AllowGroups(["Admin"]))` compiles to `@aws_auth`. AppSync evaluates
that against `cognito:groups` **before any of our code executes**, so no header we
invent can narrow it. The result is the worst state available: reads correctly
scoped, `addProduct` still callable. A mode that is right about the data and wrong
about the writes is exactly the mode someone will trust for more than it is —
and it fails in the direction where being trusted is the damage.

So the narrowing has to happen where every enforcement point already looks: in
the token's own group claim.

## §2 — What follows for free, and why that is the argument for this order

Nothing downstream needs to learn what a role is. Every layer already keys on the
caller's groups:

| Layer | Reads | After a switch |
| --- | --- | --- |
| Owner-scoped reads (four sites) | `identity.groups` via `OwnerScope` | Narrows — the caller is no longer exempt |
| Command authorization | `cognito:groups` via `@aws_auth` | Refuses — the group is gone from the token |
| Shell discovery and owner-field hiding | token groups ∩ declared elevated groups | Resolve as a scoped caller, correctly |

That is the whole reason to build the narrowing before anything that consumes it.
A design that taught each layer its own notion of "active role" would have to get
the same decision right four times, and the fourth is generated JavaScript in a
resolver template.

## §3 — The rule that carries the security

**The requested role must be a subset of actual membership.** Narrowing only,
never widening, so a client that tampers with the request can only ever reduce
its own privilege.

This is the one line in the feature where a mistake is a vulnerability rather
than a bug, and it should read that way in the source: the check belongs at the
point of minting, before any claim is written, and its test is the one that
asserts a request for a group the user does not hold is refused rather than
honoured, ignored, or silently reduced to the empty set.

Refused, specifically — not "ignored and minted as the full set". A client asking
for something it cannot have is either confused or hostile, and both are better
served by an error than by a token that does not match what was asked for.

## §4 — Local first, and it is nearly free

`/__inmemory/login` already issues and HMAC-verifies its own tokens against
`users.yaml` (`reventless/local/src/adapter/DomainGraphQL_Server.res`,
`LocalAuth.Login.issue`). The narrowed claim is therefore a parameter on minting
rather than new machinery: the body grows an optional `activeRole`, the subset
check runs against the store entry's `groups`, and the issued token carries the
one group instead of all of them.

The identity echoed back in the response has to carry the *narrowed* groups too,
not the full set — the shell reads that response to decide what to show, and a
response disagreeing with the token it accompanies would put the client one step
behind the server from the first request.

Building this half first is worth stating as a decision rather than a
convenience: it is the half with the fast feedback loop, and it makes every
consumer of the narrowing testable before a Cognito trigger exists to be
debugged.

## §5 — What this is not

**Safety, not a security boundary.** A token already issued stays valid until it
expires. Switching narrows the tokens minted *after* it and revokes nothing, so a
caller who kept an earlier token — or a request already in flight — still has the
wider claim until it lapses.

That makes this a mechanism for stopping an operator acting with elevated rights
**by accident**, which is a real and common failure. It is not a mechanism for
containing one who is trying to. Claiming the latter needs short token lifetimes
and a revocation path, which is a different project with different costs.

Document it as the former, in the reference docs and not only here, or it will be
read as the latter by someone who never saw this file.

## §6 — The AWS half

Same rule, different minting point:

- `custom:activeRole` on the user.
- A pre-token-generation trigger overriding `cognito:groups` with the selected
  role, applying §3's subset check against actual membership.
- The switch forces a token refresh, so the next request carries the narrowed
  claim.

It trails the local half rather than leading it, and the subset check must be
written twice rather than shared — the trigger runs in Cognito's own runtime with
Cognito's own event shape, and a shared helper spanning that boundary would be
carrying one line of logic across a process boundary for the appearance of reuse.
What must be shared is the **test**: the same table of (membership, requested,
expected) cases, run against both minting paths, so the two cannot drift on the
question that matters.

## §7 — Steps

1. `activeRole` on the local login body + the subset rule + the narrowed claim,
   with the response identity narrowed to match. Tests: the subset table, and
   that an unnarrowed login is byte-identical to today.
2. A caller-visible way to read the current active role back, so the shell can
   render what it is without inferring it from the group list.
2b. **Re-minting an existing session** — added on contact with the consumer, not
   foreseen here. A switch cannot go through the login path: the client holds a
   token, not a password, and re-prompting would price a navigation as a
   re-authentication. Membership is re-read from the store rather than from the
   presented token, so the record a narrowed token keeps of what it gave up
   never becomes the authority for getting it back.
3. The Cognito attribute and trigger, against the same subset table.
4. Reference docs: §5's distinction, stated where someone reading about roles
   will meet it.

Steps 1–2 stand alone and are demonstrable locally. Step 3 is independent of
everything downstream.

## §8 — Acceptance

- A login that names no active role mints exactly the token it mints today.
- A login naming a group the user holds mints a token carrying that group alone,
  and an identity in the response that says the same.
- A login naming a group the user does **not** hold is refused, and the refusal
  says so rather than falling back to a full-membership token.
- With a narrowed token: an owner-scoped list returns only the caller's rows, and
  a command the surrendered group authorized is refused by the API — not merely
  absent from a menu.
- The same three minting cases hold on both paths.
