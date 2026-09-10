# Plan: the demo cast should not live in a comment

**Date:** 2026-09-10
**Status:** filed, not started.
**Repos:** `reventless-core` only.

**Goal.** One command turns a declared list of accounts, groups and memberships into a working set of
sign-ins, with passwords generated rather than typed and written where they can be read again.

**One manifest format for both platforms, and different defaults in their templates.** The format, the
schema and the fill-in rules are shared; what a *committed template* ships for a password is a
per-platform choice, and the two answers differ for reasons §3 sets out. Sharing the mechanism without
forcing the values is the point — the alternative makes local development worse for no gain.

**Follows on from** [done/the-first-admin-should-not-need-the-console.md](done/the-first-admin-should-not-need-the-console.md),
which landed the *first* administrator. That plan deliberately stopped there. This one is the rest of
the cast — and it needs the administrator to exist first, so the order is forced rather than chosen.

**Non-goal.** Ongoing user administration. An operator adding a colleague from inside the running
product is what `IdentityProvider.createPrincipal` / `addToGroup` are for; see
[identity-is-a-capability-not-a-cognito-handle.md](identity-is-a-capability-not-a-cognito-handle.md).
This is a provisioning tool, and it should be shaped so that it becomes a *caller* of that capability
rather than a thing to delete.

---

## 1. The gap, measured

The online shop needs four accounts to demonstrate anything: an administrator, a shopper, a
merchandiser and a fulfilment operator. Its authorization annotations name three groups —
`Admin`, `Merchandiser`, `Fulfilment` — and `Shopper` besides.

**The list already exists, and so does the procedure. Neither is in a form anything can run.**

| | State |
|---|---|
| The manifest | `examples/online-shop-hybrid/platform-aws/.reventless/users.yaml` — four accounts with their groups and ids. **Gitignored**, so a fresh clone has nothing |
| A committed template | exists for **local** (`platform-local/users.example.yaml`, copied into place by a setup script). **None for AWS** |
| The AWS procedure | three `aws cognito-idp` commands per account, written as a **comment inside the gitignored YAML file** |
| The generated ids | real Cognito `sub` UUIDs, which someone created each account to obtain and then **pasted back by hand** |

So the state of the art is: read a comment in a file you only have because you made it, run a dozen CLI
commands, then copy four UUIDs back into the file. On a fresh clone none of it is there at all.

**That comment is evidence, not documentation.** Somebody hit every sharp edge in this area and wrote
the workaround in the only place they had. Two of its notes are load-bearing and must survive into the
implementation:

- `--message-action SUPPRESS`, because the pool is admin-create-only and these accounts carry no
  deliverable address.
- `--permanent`, because a temporary password leaves the account in `FORCE_CHANGE_PASSWORD` — which,
  the comment records, *the seed client rejects*.

That second note also settles a question the first-admin plan left open in its ledger as an outside
assumption. It is confirmed, in this repo, by someone who paid for it.

## 2. What makes this cheap now

The first-admin work landed every part except the loop:

- **The SDK bindings exist** — `AdminCreateUserCommand`, `AdminSetUserPasswordCommand`,
  `CreateGroupCommand`, `AdminAddUserToGroupCommand`, and `AdminListGroupsForUserCommand` for reading
  membership back.
- **The operations exist**, in `scripts/ProvisionAdmin.res`: `ensureGroup`, `ensureUser`,
  `setPassword`, `addToGroup`, all idempotent, plus `checkPoolAcceptsEmail`.
- **Password generation exists** — `generatePassword`, 24 characters from an alphabet with the
  ambiguous glyphs removed. The "what do we do about passwords" question needs no new machinery.

🚨 **Do not reach for `signUpIfMissing`.** It calls self-service `SignUp`, which an `adminOnly` pool
refuses — and `adminOnly` is the default. The first-admin work already discovered this; the bootstrap
path is `AdminCreateUser`, which works regardless of sign-up mode. Recorded here so it is not
re-derived a third time.

## 3. Steps

### Step 1 — the operations move out of the script

`ensureGroup`, `ensureUser`, `setPassword`, `addToGroup` and `generatePassword` are the shared half of
two tools. Extract them into a module both `provision-admin` and this one import — the same
one-definition-two-consumers move `Auth_LoginIdentifier` and `Auth_SignUpMode` already made, and for
the same reason: the alternative is a second copy that drifts.

`provision-admin` keeps its own behaviour exactly. This step must change nothing about it, and its
tests are what says so.

### Step 2 — one schema for the manifest, not two

The manifest format is already typed, in `reventless/local`'s `UserStore.entry`:
`{username, password, groups, userId?}`. The local platform reads it to hydrate its login store; this
tool would read the same shape to create real accounts.

**This is the seam the two platforms share, and it is the whole of what they share.** One format, one
schema, one set of rules about filling in blanks — so a cast declared once is legible to both, and a
manifest that works on one cannot silently mean something else on the other.

🚨 **What they do with it is intrinsically different, and the plan should not paper over that.** On
local the manifest **is** the user store: `UserStore.load` hydrates from it at startup, so there is no
principal to create and nothing to provision. On AWS the accounts live in a pool and the file is only a
record of them. So the shared step is *preparing* the manifest — validating it, filling empty passwords
and ids — and only the AWS side goes on to create anything. That is not a gap in the local half; it is
the local half already being finished.

**Two readers of one file must not have two definitions of it.** Move the schema somewhere both
packages can reach. Where is the open question of this step: `spec` is the obvious home, but the type
carries a plaintext password field, and putting that in the package every plugin depends on deserves a
second look before it is done.

*If that lands badly, the fallback is that this tool owns the schema and `local` keeps its own* — but
then a manifest that works on one platform can silently fail on the other, which is exactly the class
of divergence this repo has been paying down all week.

### Step 3 — the template ships the cast; what it ships for a password differs by platform

A committed `users.example.yaml` for `platform-aws`, matching what `platform-local` already has, listing
the four accounts and their groups.

🚨 **The AWS template must carry no passwords.** A Cognito pool is reachable from the internet, so a
committed password would mean every Reventless demo anyone deploys shares four published credentials.
The structure is the valuable part and none of it is secret; the passwords are generated per
deployment.

**The local template keeps `admin`/`admin`, and that is a decision rather than an oversight.** The
mechanism is shared — one format, one schema, one fill-in step (Steps 2 and 4) — but the *value* a
template ships is a per-platform choice, and forcing them to match would make the common case worse:

| | Local | AWS |
|---|---|---|
| Where the password lives | plaintext in an in-memory `Dict`, compared with `stored === password`, gone on restart | a real user pool |
| Who can reach it | the machine it runs on | the internet |
| How often a human types it | dozens of times a day | about once |
| A committed value means | every developer types the same throwaway string on their own laptop | every deployed demo shares four published credentials |

The local store hashes nothing and salts nothing; it is a development fixture, not a security boundary.
Generating a 24-character password to place in a plaintext dictionary would add no protection and cost
a copy-paste on every sign-in. Memorable is the correct answer there, and the shouty warning already on
that template is the right mitigation.

*Where local really is exposed* — a shared dev box, a tunnel, a demo over the office network — the
answer is not a generated password, which would still sit in plaintext beside it. It is not exposing
the local platform, which is what that warning is already reaching for. Recorded so the asymmetry is not
later "fixed" into symmetry by someone reading only one half of it.

### Step 4 — the command

Two halves, and the split is Step 2's: **prepare** the manifest, then **apply** it.

*Prepare* is platform-neutral — validate the entries, generate a password into any empty field,
and write both back. A local manifest needs only this, and gets it from the same code.

*Apply* is the AWS half: for each entry, ensure the groups it names, ensure the account, set the
password, apply the memberships.

Both halves **write back into the working file**:

- the generated password, **only where the field is empty** — never overwriting one already there, so
  a second run is safe and an operator's own choice is never clobbered
- the account's generated id, which removes the paste-the-UUID step entirely

Writing back is what answers "where do the passwords go so they can be used later without saving them
somewhere": the working file is already the place credentials live for this deployment, and it is
already what the seed client reads to sign in. The tool fills it in instead of a person.

*Idempotency is the property to test, not the happy path.* Everything under it is already idempotent;
what is new is the file write, and the failure mode is a second run silently replacing a password
somebody is using.

### Step 5 — generic tool, example-supplied manifest

The command must not know the shop's four accounts. The manifest belongs to the example. Any
application then gets the same bootstrap by writing its own list, and the shop stops being a special
case.

**Where the two halves live follows Step 2.** *Apply* is Cognito-specific and belongs in
`reventless/aws`. *Prepare* is neither platform's, and putting it beside *apply* would leave the local
half reaching into the AWS package for a file operation that has nothing to do with AWS — so it belongs
wherever the shared schema lands.

That also quietly widens what this is for: a team standing up a real deployment has staff to create
before the product can administer anyone, and this is that tool. Worth building for, not worth
claiming until someone asks.

### Step 6 — say it once, where the last page says it

`packages/doc/docs-app/first-admin.md` now ends at the administrator. Extend it — or add its sibling —
with the rest of the cast, and link it from the shop's own getting-started path, which is where someone
following the demo actually is.

## 4. Verification

- From a clone with no `.reventless/users.yaml`: copy the template, run the command, and sign in as
  each of the four — including reading a view that only that account's group may read. The last clause
  is the test; four created accounts prove nothing if the group memberships did not take.
- The seed client runs against the result without further edits. It reads this file already, so this
  is the real integration and not a proxy for one.
- A second run changes no password and reports every account as adopted.
- A password already present in the file survives the run.
- **The local platform is unchanged**: its committed template still ships `admin`/`admin`, and a
  developer who has never run this command signs in exactly as they do today. The shared code is
  reachable from local, not imposed on it.
- A local manifest with an empty password field is filled by *prepare* alone, with nothing provisioned
  and no AWS credentials required — the half that proves the split in Step 2 is real.
- `provision-admin` behaves identically before and after Step 1, held by its existing tests.
- Full build warning-free, whole suite green, format gate green.

## 5. Honesty ledger

- **Read off code, and it is what settles §3's asymmetry:** `LocalAuth.Login` stores a password
  plaintext in an in-memory `Dict` and authenticates with `stored === password` — no hash, no salt,
  discarded on restart. That is a development fixture, not a security boundary, which is why generating
  a password for it would buy nothing and cost a copy-paste per sign-in.
- **Read off code:** that both `users.yaml` files are gitignored and only `platform-local` has a
  committed template; that the AWS file lists four accounts with groups and real `sub` UUIDs, and
  carries the three-command CLI recipe in a comment; that `UserStore.entry` types the manifest; that
  `ProvisionAdmin` exposes `ensureGroup` / `ensureUser` / `setPassword` / `addToGroup` /
  `generatePassword`; that all five needed Cognito command bindings exist.
- **Confirmed in-repo, having been an outside assumption:** that an administrator-created account lands
  in `FORCE_CHANGE_PASSWORD` and needs a permanent password set. The first-admin plan flagged this as
  unverified; the YAML comment records it as lived experience, and `provision-admin` already acts on it.
- **Not investigated:** whether the seed client's account selection needs anything beyond what the
  manifest already carries, and whether four accounts is the right cast at all — that list is inherited
  from whoever built the demo, not derived from what the demo needs to show.
- **Design proposal, not validated:** the write-back. It is the part with no precedent here, it mutates
  a file a human also edits, and Step 4's "only fill empties" rule is the whole of its safety. If that
  rule proves awkward, printing the passwords and leaving the file alone is the fallback — worse to
  live with, but it cannot destroy anything.
- **Unresolved, and named rather than assumed away:** where the shared manifest schema lives (Step 2).
  A plaintext password field in `spec` is a real objection and this plan does not overrule it.
