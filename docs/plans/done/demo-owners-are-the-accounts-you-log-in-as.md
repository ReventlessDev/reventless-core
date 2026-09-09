# Plan: the demo owners are the accounts you log in as

**Date:** 2026-09-09<br/>
**Status:** DONE. Found by opening *My Notification Preferences* on a deployed
hybrid stack as `admin` and getting "Showing all 0 items" while the view's table
held 10 rows. Not a defect in the notification chain, the projection or the owner
resolver — all three are correct. The demo data was keyed to the **local**
platform's user ids, so on any Cognito-backed deployment no owner-scoped row
belonged to any account you could actually sign in as.

All five steps are implemented. Verified against an isolated local platform
(alt ports, scratch store) across four runs, one per arm:

- **arm 1** — the accounts file's `userId`: resolution reported, and the demo
  shopper reads back exactly 5 orders, 1 subscription and ≥ 1 delivery under its
  own narrowed token.
- **arm 2** — the bearer: on the `REVENTLESS_DEMO_USER`/`REVENTLESS_DEMO_PASSWORD`
  path the operator resolves from the run's own token, and Step 5 skips without
  failing. **Verified locally only, and it did not work on AWS as first shipped**
  — `Seed_Client.claims` took the first segment that decoded to a JSON object,
  and a JWT's JOSE header is one, so on every real Cognito token it read
  `{kid, alg}` as the claims set. `callerId` therefore answered `None` there, and
  so had `effectiveGroups` and `identitySummary` since long before this plan.
  Fixed by skipping a decoded segment carrying `alg`; the test helper's fake
  header did not decode, which is why no test could express the bug.
- **arm 3** — the fallback literal: reported and warned.
- **the regression itself** — a deliberately stale `userId` seeds 40 orders and 10
  subscription rows that `verifyViews` counts happily, and Step 5 fails naming
  the cause. That is the assertion nobody had written.

Acceptance items 2 and 3 are the deployed halves and need a stack; the local
equivalents of both passed. One rough edge left as-is: a Step 5 failure prints
`Seed_Runner.run`'s generic "the store is now half-seeded" line, which is
imprecise — the store is fully seeded, just keyed wrong. Its advice (reset and
re-seed) is still the right recovery.<br/>
**Relates to:**
- [owner-scoped-identity-and-reads.md](owner-scoped-identity-and-reads.md)
  — the feature this misses; the read narrowing works exactly as specified.
- [owner-scoped-reads-on-an-index.md](../owner-scoped-reads-on-an-index.md) — the
  physical read a narrowed caller takes. Unaffected: it returns nothing because
  nothing matches, not because it looks in the wrong place.
- [online-shop-hybrid-demo-data.md](online-shop-hybrid-demo-data.md) —
  where `demoShopperId`/`demoOperatorId` were introduced.
- [active-role-narrows-the-token.md](../active-role-narrows-the-token.md) — why the
  seeding run and the browsing session can hold different exemptions.

---

## The symptom

Signed in as `admin` with the active role **Shopper**, three owner-scoped views
render empty on a deployed stack:

| View | `@owner` field | Rows in the table | Rows the shopper sees |
| --- | --- | --- | --- |
| `Ordering_NotificationSubscriptions` | `recipientId` | 10 | 0 |
| `Ordering_NotificationDeliveries` | `recipientId` | 70 | 0 |
| `Ordering_Orders` | `customerId` | 41 | 0 |

Every row in all three is keyed to `cust-01`…`cust-08`, `local-shopper` or
`local-admin`. The account's own id is the Cognito `sub` recorded in
`platform-aws/.reventless/users.yaml`, and it appears on none of them.

An operator role shows all the rows, which is what makes this read as a
notification bug rather than a seeding one: the data is plainly there.

## The defect

`DemoData.res` names the two demo owners as literals:

```rescript
let demoShopperId = "local-shopper"
let demoOperatorId = "local-admin"
```

Those are the `userId` values `platform-local/.reventless/users.yaml` assigns —
the in-memory auth adapter takes the id from the file, so locally the literals
*are* the signed-in identity and every demo walkthrough works. On AWS the id is
the pool's `sub`, minted by Cognito and not settable. `platform-aws`'s own
accounts file already says so in as many words:

> `userId` — On AWS this is the Cognito `sub`, minted by the pool — it is NOT
> settable the way `userId: local-shopper` is locally. Owner-scoped rows
> (`@owner`) are keyed by these subs, so data created locally is invisible to the
> matching AWS account and vice versa.

The seed reads that file to *pick a login* and never reads it again. The literals
survive into the commands, and the demo customer `local-shopper` is registered on
a deployment where nobody can ever be `local-shopper`.

For notifications the chain then works perfectly and produces nothing usable. A
subscription row exists only after `Customer.Registered` → `AnnounceRecipient` →
`RecipientAnnounced`. `AnnounceRecipient` is `@noApi` and carries no `@owner`, so
its `recipientId` is the **Customer aggregate id the seed chose** — by design,
since a caller who could announce someone else's address would be redirecting
their mail. There is no client door that would let a real account register
itself, and the seed never opens the one door there is.

The order placed by hand through the UI confirms the whole path is healthy: it
carries the caller's real `sub`, it produced a `NotificationDeliveries` row, and
that row reads `outcome: Undeliverable` with an empty channel — the directory
correctly refusing to send to a recipient it has no announced address for.

## Why nothing caught it

`Seed.Runner.verifyViews` counts each view with the **seeding** client, which
holds an elevated token. `Ordering_NotificationSubscriptions` answers 10, the
run reports success, and the assertion that would have failed — *does the demo
shopper see its own rows?* — is not one anybody wrote. The harness exists to
remove the "is it broken or is it empty?" ambiguity and reproduces it exactly
one layer up: the view is non-empty for the seeder and empty for every human.

`Seed_Prompt.fromUsersFile` already carries the comment that names this failure —
"which identity seeded the data is the thing an operator checks when owner-scoped
rows turn up under the wrong account" — and logs the username. The username was
never the missing half; the id was.

---

## Step 1 — `Seed_Users` reads `userId`

`Seed_Users.user` parses `username`, `password` and `groups` and drops `userId`.
Add it as `option<string>`: absent is normal (a local file may omit it and let it
default to the username; a hand-maintained AWS file may lag the pool).

`label` is unchanged — the menu still shows username and groups.

## Step 2 — a cross-provider caller id on `Seed_Client`

`claims` already decodes whichever segment carries the payload. Add a
single-string claim reader and the id getter beside `effectiveGroups`:

```rescript
/** Claim carrying the caller's id, per provider, tried in order. A Cognito JWT
    says `sub`; the local dev token is a base64url `Identity.t`, whose field is
    `userId`. */
let callerIdClaimNames = ["sub", "userId"]
let callerId: t => option<string>
```

Same shape as `groupClaimNames`, for the same reason: the harness depends on no
framework package and must not learn which provider signed the token.

## Step 3 — the connection carries the identities

`Seed_Prompt.credentials` returns `(username, password)` and discards the account
list it just read. Widen it to return the resolved account alongside the list,
and put both on the connection:

```rescript
type connection = {
  client: Seed_Client.t,
  uploadsSkipped: bool,
  label: string,
  // Every account the platform's accounts file declares. A data set resolves a
  // demo owner through this, so the id it seeds is the id the platform stamps.
  accounts: array<Seed_Users.user>,
  // The account this run authenticated as, and the id its bearer actually
  // carries — which is the only id available when there is no accounts file.
  caller: Seed_Users.user,
  callerId: option<string>,
  // The login this run authenticated with. Step 5 mints a second bearer for
  // another account, and only the caller of `make` knows how to mint one.
  login: (~username: string, ~password: string) => promise<string>,
}
```

`accounts` is `[]` on the non-interactive path
(`REVENTLESS_DEMO_USER`/`REVENTLESS_DEMO_PASSWORD` bypass the file entirely), so
every consumer must handle empty rather than assume the file was there.

**`login` was not in this plan's first draft, and Step 5 does not work without
it.** Where the bearer comes from is deliberately the caller's concern —
`Seed_Connect.make` takes `~login` and never learns whether it is a Cognito
round-trip or a local `/__inmemory/login` — so a connection that dropped it after
the first use left the harness able to authenticate exactly once. Keeping it, plus
a `Seed_Connect.clientFor(connection, ~account)` beside `make`, is what lets a
data set read its own rows back as somebody else without any of it learning who
signs tokens.

`credentials` returns a named `resolved = {caller, accounts}` rather than a tuple:
two same-typed halves that are both "accounts" read wrong at every call site.

## Step 4 — `DemoData` resolves its owners instead of naming them

Turn the two literals into a resolution, done once at the top of
`HybridSeedData.run` where the connection is in scope and before
`DemoData.demoCustomers` and `DemoData.buildOrders` are used. Per demo owner, in
order:

1. the accounts file entry with that username, if it declares a `userId`;
2. else, when the run authenticated **as** that account, the id from its bearer;
3. else the existing literal.

The username → demo-owner mapping (`shopper` is the demo shopper, `admin` the
demo operator) is domain knowledge and belongs in `DemoData`, not in the harness.
`demoCustomers` becomes a function of the resolved pair, and `buildOrders` takes
them as arguments — its fixed-count assignment by index is otherwise unchanged,
and the generated `cust-NN` customers stay exactly as they are. They are third
parties on purpose: "the shopper sees no other orders" needs somebody else to
hold the rest.

**Report the resolution, and warn on arm 3.** One line naming each demo owner and
where its id came from, and a warning that says the seeded rows will be invisible
to every account on this deployment. Silence is what turned this into a
browser-side mystery; a run that cannot key its data to a real account should say
so while it still means something.

**Arm 3 warns every time, not only when the literal "does not look like" the
platform's ids** — which is what this plan first asked for, and which cannot be
written. The only sample of what an id looks like here is the run's *own* caller
id, and that belongs to a different account, so it is *supposed* to differ from
the demo shopper's: comparing them warns on every correct run and stays quiet on
some wrong ones. Shape-matching a Cognito sub against `local-shopper` would be a
guess about a guess. So the fallback itself is the warning — nothing on the
platform named an id for that account, which is exactly the state that cannot be
verified — and the caller id is quoted as *evidence* ("this run's bearer carries
`local-admin`, which is what an id looks like here") rather than used as the test.

It costs nothing where the demo is healthy: a complete accounts file resolves both
owners through arm 1 and never reaches the fallback, so a working local run is
silent.

**A second warning, not in the original plan: the stale accounts file.** When the
run authenticated as one of the demo owners and the file's `userId` for that same
account disagrees with the id its bearer actually carries, arm 1 wins with a value
the platform will never stamp. The plan itself names this risk ("a hand-maintained
AWS file may lag the pool") and then orders the file ahead of the bearer anyway.
That ordering is kept — the file is what the other owner is resolved from too, and
one account's bearer should not silently override it — but the disagreement is
reported, because it is the one case where the run holds hard evidence rather than
a suspicion.

## Step 5 — an acceptance that fails when this regresses

The gap is not that the check was wrong, it is that owner scoping was only ever
verified by a caller exempt from it. After seeding, mint a second client for the
demo shopper account — the accounts file already holds its password, which is why
this costs no new configuration — and assert its owner-scoped views are non-empty
under **its own** narrowed token:

| View | Expected for the demo shopper |
| --- | --- |
| `Ordering_Orders` | exactly `demoShopperOrderCount` |
| `Ordering_NotificationSubscriptions` | exactly 1 |
| `Ordering_NotificationDeliveries` | ≥ 1 |

Exact counts, not "non-zero": correct scoping and scoping that matches nothing
are both satisfied by a non-zero total elsewhere, which is the same trap
`DemoData` already documents for the per-owner order counts.

Skip the whole step when no accounts file supplied a password — a CI run on the
non-interactive path has one identity and cannot check a second.

---

## Acceptance

1. ~~Local, unchanged behaviour: seed as `shopper`~~, log in as `shopper`, see 5
   orders and 1 subscription row. This must keep passing untouched — the literals
   and the file agree locally, so arm 1 resolves to the same values arm 3 would.

   **Seeding *as* `shopper` is not a thing that can happen**, and this item asked
   for it. A Shopper may not add a category, so the run aborts on its first
   command with `Forbidden` / "identity is not authorized" — before any of this
   plan's code is reached, and identically before the change. Even granted the
   catalog, it would not measure what the item wants: `PlaceOrder`'s `customerId`
   is `@owner`, so a non-elevated caller has every order rewritten onto itself and
   the demo shopper would hold all 40 rather than 5. Seeding needs an elevated
   account; `shopper` is the account you then **log in as**. Verified as written:
   seed as `admin`, and the demo shopper reads back 5 / 1 / ≥ 1 under its own
   narrowed token.
2. Deployed: reset, seed as any account, then log in as `shopper` with the
   **Shopper** role and see 5 orders, a full kind × channel matrix on *My
   Notification Preferences*, and delivery rows on *My Notifications*.
3. Deployed, the operator half: log in as `admin`, role **Shopper**, and see 3
   orders and its own matrix — the account whose empty screen started this.
4. Delete `userId` from one `platform-aws` account entry and re-run: the run
   reports the fallback and warns, rather than seeding silently invisible rows.
5. CI path (`REVENTLESS_DEMO_USER`/`REVENTLESS_DEMO_PASSWORD`, no accounts file):
   the run completes, resolves the seeding account through arm 2, and skips
   Step 5's second-identity assertions without failing.

## Also done, not in any step above

- **Tests, in the harness only.** `Seed_UsersTest` pins that `userId` survives the
  parse and that an absent one stays absent rather than defaulting to the username
  (guessing there would look like an answer), plus that `label` still says nothing
  about it — a Cognito sub in the account menu is noise at the moment somebody is
  choosing a login. `Seed_ClientTest` pins `callerId` across both providers, `sub`
  winning over `userId`, and a refusal to read a claim that is not a single string.
  The resolution in `DemoData` itself is covered by the run rather than by a unit
  test: `seed-data` declares no `tests` dir and no jest project, and adding one to
  an example package for this was more than the change warranted.
- **Both accounts files now say `userId` is read.** The committed
  `platform-local/users.example.yaml` gained a note that deleting a `userId` makes
  that account's demo rows invisible to it. The gitignored
  `platform-aws/.reventless/users.yaml` said, in as many words, "That is all it is
  read for" — true when written and the exact sentence that would send the next
  reader past the cause.

## What this does not change

- **No domain change.** `AnnounceRecipient` stays `@noApi` and stays without
  `@owner`; a client that could announce its own recipient id could announce
  anyone's. The graft point is correct as written.
- **No owner-resolver change.** The narrowing, the `_owner` index and the
  elevated exemption all behave as specified. The rows simply did not exist.
- **Existing deployed data is not migrated.** Owner ids are on events, not
  derived on read, so a re-key is a reseed against a reset store — which is what
  the harness is for, and it refuses to run against a non-empty one anyway.
- **`cust-NN` customers keep their generated ids.** They are meant to be people
  you cannot log in as.
