# Plan: a play file says what each step expects

**Date:** 2026-11-22<br/>
**Status:** ✅ Built and released 2026-11-22: [PE1](#pe1-the-client-expects-an-answer-and-reads-a-row) to [PE7](#pe7-the-checks), the shop's file
played on its alpha stack too (see [§8](#8-as-built)). A step that only reads a row and an answer that
may meet an earlier play came after, built, not yet released. Steps numbered PE1 to PE7, decisions PED1 to PED4, open questions PEQ1 to PEQ4,
each with a recommendation, all four answered as recommended. *PE* is short for *play,
expected*.<br/>
**Repos:** `reventless-core` only: `reventless/seed`, `reventless/seed-aws`, the hybrid shop's
seed data.<br/>
**Builds on:** [seed-plays-forward-as-a-player.md](done/seed-plays-forward-as-a-player.md), which
gave the seed its play file (`SEED_FILE`), and
[an-app-declares-its-environments.md](an-app-declares-its-environments.md), which gives every
deployment a purpose.<br/>
**Facts from:** this repo at `2d3fc069a`, surveyed 2026-11-22.

> **Questions and short answers**
>
> - *What does this plan add?* **A play that can fail.** A step of a play file says what it
>   expects (accepted, or refused with a code) and which row a view must then show; the seed
>   stops at the first step that went otherwise and says what came instead
>   ([PE1](#pe1-the-client-expects-an-answer-and-reads-a-row) to [PE3](#pe3-the-result-as-data)).
> - *Can the same file run locally and on a deployment?* **Yes.** A person's id is written as
>   `{id:ada}`, the id of the account that plays Ada wherever the file is played
>   ([PE4](#pe4-a-persons-id-in-a-play-file)).
> - *Can a play that expects write into production?* **No.** It is refused on a deployment whose
>   purpose is `production` or says none ([PE5](#pe5-a-play-that-expects-stays-off-production)).
> - *Do data sets change?* **No, but they can use it.** Expecting and reading are calls of the
>   seed client, which a data set already sends through; the hybrid shop's hand-written refusal
>   becomes one call ([PE6](#pe6-the-hybrid-shops-data-set-uses-it)).

---

## 1. In plain words

The seed plays two kinds of thing into an app. A **data set** is ReScript (`Seed.dataSet`): a
program that seeds with logic, volume, uploads or what the app holds now, as the hybrid shop's
`HybridSeedData` does. A **play file** is YAML (`SEED_FILE`): a fixed list of steps, each a
mutation by name, its arguments and the person it is sent as. *Seed data* is at most the folder
that holds both.

A play file today only sends. A step the app refuses stops the run, but a step meant to be
refused cannot be written, and nothing says what a view should show after it. So a play that went
wrong reads as one that went right, unless a command was refused by accident. A play file that
says what each step expects is a test of a running app, local or deployed: it finds what only a
running app can get wrong, such as an automation not deployed, a view fed by nothing, or a role the
deployment does not give.

## 2. What the seed does today

| Piece | What it does | Where |
|---|---|---|
| The play file | `send` with `args` and `as`, `waitFor` with a view and ids; `{run}` and `{rep}` in values; `pace`, `repeatable` | [`Seed_Play`](../../reventless/seed/src/Seed_Play.res) |
| Sending | `Seed_Client.send` throws on `CommandRejected` unless its code is in `~tolerate`, which it then returns | [`Seed_Client`](../../reventless/seed/src/Seed_Client.res) |
| Waiting | `waitForIds` polls `<View>ByIds` until every id is there, or throws after a time | the same |
| Who sends | each `as` name signs in once as the account that plays it, from the accounts file (`demoOwner`, else username); `callerId` reads the token's `sub` | [`Seed_Accounts`](../../reventless/seed/src/Seed_Accounts.res), [`Seed_Connect`](../../reventless/seed/src/Seed_Connect.res) |
| A deployment's purpose | the deploy writes `environmentPurpose` into the served `config.json`, from `environments.yaml` | [`Environments`](../../reventless/spec/src/types/Environments.res) |
| Wiping | only a stack whose Pulumi config says `reventless:wipeable: "true"` | [`ReventlessSeedAws_Reset`](../../reventless/seed-aws/src/ReventlessSeedAws_Reset.res) |
| A refusal on purpose | the hybrid shop adds a product twice and checks the `ProductAlreadyExists` by hand | [`HybridSeedData`](../../examples/online-shop-hybrid/seed-data/src/HybridSeedData.res) |

Two gaps sit beside the missing expectations:

- **A person's id differs between platforms.** Locally an account's id is its name (`ada`); on
  AWS it is the sign-in's `sub`. A file that sends `driverId: ada` makes, on AWS, a thing that
  belongs to nobody who can sign in, and a rule that lets only its owner act refuses Ada.
- **A run given a password reads no accounts file.** With `REVENTLESS_DEMO_USER` and a password
  set, the seed signs in without the accounts file, and a step with `as` finds no account. A run
  with no terminal can only name its user alone.

## 3. The shape

```yaml
# A play file that expects, on the hybrid shop. The comment above a step is the writer's.
pace: 1s
steps:
  # Ada registers
  - id: register
    send: Ordering_Customer_Register
    as: ada
    args: {id: "cust-{run}", email: "ada.{run}@example.com", address: "1 Market Street"}
    expect: accepted
  # Ada orders two of a product
  - id: order
    send: Ordering_PlaceOrder
    as: ada
    args: {orderId: "ord-{run}", customerId: "cust-{run}", lineItems: [{productId: "prd-1", quantity: 2}], shippingMethod: Standard}
    expect: accepted
    row: {view: Ordering_OrdersByIds, key: "ord-{run}", has: {customerId: "cust-{run}", shippingMethod: Standard, lifecycle: "{any}"}}
  # The same order again is refused
  - id: order-again
    send: Ordering_PlaceOrder
    as: ada
    args: {orderId: "ord-{run}", customerId: "cust-{run}", lineItems: [{productId: "prd-1", quantity: 1}], shippingMethod: Standard}
    expect: {refused: OrderAlreadyPlaced}
```

- `id` is optional, and is echoed in the result, so a writer can find its own step again.
- `expect` is `accepted` or `{refused: <code>}`; without it a step sends as today.
- `row` reads one row of a `<View>ByIds` field by its key, as the step's person, until it has the
  values in `has` or a time is up. `"{any}"` asks only that the field has a value: a time the app
  stamps, or a state an automation moves on, is never known before.
- A value that is a person's id is written `{id:ada}` ([PE4](#pe4-a-persons-id-in-a-play-file)); the shop's customer ids are its own,
  so this file needs none.

## 4. Steps

### PE1 The client expects an answer and reads a row

- **`Seed_Client.sendExpecting(m, ~expect: Accepted | Refused(code))`** returns what came
  (accepted, or refused with its code and detail) and whether it is what was expected, instead of
  throwing. A refusal from the infrastructure is retried as `send` retries it.
- **`Seed_Client.readRow(~field, ~key, ~has, ~timeoutMs)`** polls `<field>(ids: [key])` with the
  fields `has` names, until each has its value (`"{any}"`: has one), and returns the row as it
  last came and how long it took. A field the caller may not read is said as that, not as a row
  that never came.
- `send` and `waitForIds` stay as they are.

### PE2 The play file expects

- **`expect`** and **`row`** on a `send` step, read through [PE1](#pe1-the-client-expects-an-answer-and-reads-a-row). A step answered otherwise stops
  the file there, and says the step (its `id`, else its number), what was expected and what came.
- **The preflight checks them too:** a `row` whose field the API does not have, or whose `has`
  names a field the view does not have, is refused before anything is sent, as an unknown
  mutation is today.

**Exit:** a file against the hybrid shop, locally, with one step refused as expected, one row
read, and one step whose answer differs, stopped and reported at that step.

### PE3 The result as data

- **`SEED_RESULT=<path>`** writes, beside what the seed prints, a JSON record of the run: the
  platform, the run's tag, and per step its `id`, mutation, person, what was expected, what came,
  and for a row the values read and how long it took.
- The file is written when the run stops, at a step or at the end, so a stopped play still says
  where.

### PE4 A person's id in a play file

- **`{id:<name>}`** in a value is the id of the account that plays that person on the platform
  the file is played into: `Seed_Client.callerId` of that person's client, signed in once as `as`
  signs in today. Locally it is the account's id; on AWS its `sub`.
- It is filled in `args` and in a `row`'s `has` alike, so a row whose owner is Ada is found as
  hers.
- **The accounts file is read whenever a step names a person**, whether or not the run's own
  user was given with a password; the run's user signs in as before.

**Exit:** the same file played locally and on the shop's alpha stack, each row's owner the id of
the account it signed in as.

### PE5 A play that expects stays off production

- **A play file with any `expect` or `row`** is played only where the platform says its purpose:
  locally always; on a deployment only when its served `config.json` has an `environmentPurpose`
  other than `production`. A deployment that says none is refused, as the shell draws it in the
  colour of the unknown.
- **The run's mark is required:** such a file is refused when no value has `{run}`; an `ID`
  argument (by the API's introspection) with neither `{run}` nor `{id:…}` is said as a warning, so
  a file that reaches for something that exists before it is allowed, and seen.

**Exit:** a file that expects, refused on a deployment whose config says no purpose, and played
on the shop's alpha stack (`dev`).

### PE6 The hybrid shop's data set uses it

- `seedRejectedDuplicate` becomes one `sendExpecting(…, ~expect=Refused("ProductAlreadyExists"))`,
  and its report what that returns.
- The shop gains a short play file that expects, in `seed-data/play/`, beside `traffic.yaml`: a
  customer registers, orders, is refused a second order with the same id, and the order shows on
  its view, as in [§3](#3-the-shape).

### PE7 The checks

Tests of [PE1](#pe1-the-client-expects-an-answer-and-reads-a-row) to [PE5](#pe5-a-play-that-expects-stays-off-production) against the local platform, as the seed's tests run today; the shop's new file played on
its alpha stack by hand, once, and the run recorded below as *As built*.

## 5. Decisions taken

| Id | Decision | Taken 2026-11-22, as recommended |
|---|---|---|
| PED1 | Expecting and reading live in the seed client, and the play file reads through them | yes: a data set and a play file then report a step that went otherwise the same way |
| PED2 | A step that went otherwise stops the play | yes: what follows it was written for a world it did not make |
| PED3 | The guard uses the purpose the deployment says about itself (`environmentPurpose`), not the stack's name or `reventless:wipeable` | yes: the purpose is what `environments.yaml` declares and the deploy records; wipeable says only that a stack may be emptied |
| PED4 | A play writes, marked by its run, and nothing is wiped | yes: a play that needs an empty platform cannot run where people work |

## 6. Open questions

**PEQ1.** *Does a `row` compare a value exactly, or as the API shapes it?* A case comes back as
its name, an option as its value or `null`. **Recommendation:** exactly, against the API's shape:
the file is written in the shape `args` already take, and the seed does not guess.

**PEQ2.** *Is a `demo` deployment played on?* It is not production, and people show it.
**Recommendation:** yes: a play's mark keeps it apart from what a presenter made, and a demo
deployment is where a play shows it still works before the demo.

**PEQ3.** *Should a play read every view after a run, as a data set's `Seeded` and `Unfillable`
views do?* **Recommendation:** not in this plan: a play reads the rows its steps name. A later
reading of every view takes the `Seeded`/`Unfillable` shape the runner has, not a new one.

**PEQ4.** *How long does a `row` wait?* **Recommendation:** 60 seconds by default, as
`waitForIds`, and `SEED_ROW_TIMEOUT` to change it; the result says how long each row took, so a
slow deployment shows before it fails.

## 7. Risks

| Risk | What keeps it small |
|---|---|
| A play writes into production | [PE5](#pe5-a-play-that-expects-stays-off-production): only where a purpose other than `production` is said |
| Two plays, or a play and a person, meet in one view | `{run}` required, and every `ID` without it said ([PE5](#pe5-a-play-that-expects-stays-off-production)) |
| A view that fills late reads as a stop | [PE1](#pe1-the-client-expects-an-answer-and-reads-a-row) polls until a time, and [PE3](#pe3-the-result-as-data) says how long each row took |
| A person's id differs between platforms | [PE4](#pe4-a-persons-id-in-a-play-file): the id is the account's, found where the file is played |

## 8. As built

Built 2026-11-22 as planned. Where it differs, or what the build showed:

- **The client** ([PE1](#pe1-the-client-expects-an-answer-and-reads-a-row)): `Seed_Client.sendExpecting(m, ~expect)` returns the answer and whether
  it meets `~expect`; `readRow(~field, ~key, ~wanted, ~timeoutMs)` returns the row as it last came,
  whether it matches, whether the reader was refused, and how long it waited. The decisions are
  pure functions beside them (`answerOf`, `meets`, `has`, `selectionOf`), tested without a
  platform. A refusal of the caller is `Forbidden` on both platforms, whichever code or error
  carries it.
- **A refused read on the local platform** is an empty list, as `checkQueryAccess` already notes:
  a row the step's person may not read reads there as a row that never came; on AppSync it is
  said as a refusal.
- **The preflight** ([PE2](#pe2-the-play-file-expects)) reads the API's query fields and each row type's fields, and
  refuses a view the API does not have and a value a row does not carry; nested values are
  checked when read, not before.
- **The purpose** ([PE5](#pe5-a-play-that-expects-stays-off-production)) travels on the connection (`purpose`): `local` from the local
  platform, `environmentPurpose` from a deployment's host-shell `config.json`. A stack that serves
  no host shell says no purpose, so a play that expects is refused there.
- **The accounts file read with a password** ([PE4](#pe4-a-persons-id-in-a-play-file)) changed more than plays: the shop's
  follow-up run now finds its demo owners' accounts on the non-interactive path and checks each
  owner's own reads, which it used to skip. The player test that counted the run's lines now counts
  the growth check's own.
- **The shop** ([PE6](#pe6-the-hybrid-shops-data-set-uses-it)): `seedRejectedDuplicate` is one `sendExpecting`, and
  `seed-data/play/order-placed-once.yaml` makes its own category, product and customer, orders,
  reads the order's row and is refused the same order again.
- **The checks** ([PE7](#pe7-the-checks)): the client's and the file's decisions as unit tests, the player against
  a fake API (a refusal as expected, an answer that differs, a row that never comes, a person's
  id), and the shop's file played into the running local platform twice: to the end with its
  result written, and with one wrong expectation, stopped at that step.
- **The open questions** ([§6](#6-open-questions)) went as recommended: a row is compared exactly in the API's
  shape; any purpose but `production` is played on, `demo` included; a play reads only the rows
  its steps name; a row waits 60 seconds, `SEED_ROW_TIMEOUT` to change it.

**Played on alpha** (2026-11-22, run `20261122T100428`): the shop's file, signed in as `admin`
from the accounts file, on the stack whose `config.json` says `dev`. Every step went as it
expects: the category, product, customer and order accepted, the order's row read on
`Ordering_OrdersByIds` after 413 ms with its customer, two items, `Standard` and a `placedAt`, and
the same order again refused with `OrderAlreadyPlaced`. What it made stays on alpha, marked by the
run. A play that ended well then printed nothing after its run line; it now closes with *every
step went as it expects (5 steps)*.

**A step that only reads a row** (added after the release, when the tools wrote a story's steps
into a play file): a story's step that looks at a view is its own step, as its own person, and
sends nothing. A step with `row` and no `send` (`{id, as, row}`) reads the row as its `as`, counts
as a step that expects, and is checked before the play as any `row` is.

**An answer that may meet an earlier play** (added after the release, for the same reason): a
story's cast is there before it, so the step that registers Ada is refused when the story is played
a second time on one deployment. `expect: {acceptedOr: <errorCode>}` takes that refusal as the step
having gone as expected; any other refusal still stops the play.
