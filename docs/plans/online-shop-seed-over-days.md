# Plan: seed the online shop over several days

**Date:** 2026-09-17
**Status:** IN PROGRESS — steps 1 to 6 done and tried on a local platform (2026-09-17);
step 7 (trying it on AWS on later days) remains. See [Progress](#progress).
**Repos:** `reventless-core` only.

## In plain words

The online-shop example has a seed: a script that fills a fresh shop with demo data
by sending real commands — add these categories and products, register these
customers, place these orders. It runs once, in a few minutes.

That is why every chart about *when* things happened looks empty or has one spike.
The shop records the time of every event itself, at the moment it accepts the
command. It is not a value the seed can choose. So after one run, every order was
"placed at 06:45 today", every notification was sent a few seconds later, and every
price change happened in the same minute as the product it changed.

Running the seed again does not help. It refuses a shop that already holds data, and
even without that refusal it would send the same commands with the same ids, which
the shop rejects as duplicates.

This plan splits the seed into a **first run**, which creates the shop, and a
**follow-up run**, which can be repeated on later days and adds what a real shop
sees over time: price changes, new products, new customers, new orders, shipments
and cancellations. Run the follow-up on a few different days and the data spreads
over those days — for real, because the events really happened then.

## Goal

1. The first run still fills an empty shop in one go, and still exercises every
   path the seed exercises today.
2. A follow-up run, started on any later day, adds a small, believable day of
   activity to that shop, and says what it added.
3. After a first run and three follow-ups on three different days, the Orders
   trend, the notification deliveries and the lifecycle trails show activity on four
   days.

## Not part of this plan

- **Setting an event's time from the seed** ("backdating"). It would turn the
  recorded time into a claim made by the caller, and automations would still react
  at today's time, so a backdated order's trail would read out of order.
- **Running follow-ups on a schedule.** Once a follow-up exists, a scheduled job is
  only a way of starting it. That job, and the credentials it needs, can be a
  plan of its own.
- **Giving the delivery window behaviour in the domain** — for example, shipping an
  order only when its window comes close. The window stays display data; this plan
  only makes the seeded windows consistent with what happens to the orders.
- **A different set of demo data.** Products, categories and names stay as they are.

## Words used in this plan

- **First run** — today's `full` and `sample` data sets: fill an empty shop.
- **Follow-up run** — the new data set, `next`: add one day of activity to a shop
  that a first run filled.
- **Run date** — the UTC day a run starts on, for example `2026-09-24`. A follow-up
  run is named by its run date.
- **Demo accounts** — the sign-ins in `users.yaml` (shopper, operator, merchandiser).
  Their order counts are fixed and checked at the end of a first run.

## How the seed works today

All in [`seed-data`](../../examples/online-shop-hybrid/seed-data):

- **Data sets.** [`HybridSeedData.res`](../../examples/online-shop-hybrid/seed-data/src/HybridSeedData.res)
  exports `full` (60 products, 20 customers, 150 orders) and `sample` (16, 8, 40), plus an
  authorization check. `SEED_SET` picks one; otherwise a menu asks.
- **Empty-shop check.** Before sending anything, the runner reads a list of views
  (`probeViews`) and refuses if any holds a row.
- **Fixed data.** [`DemoData.res`](../../examples/online-shop-hybrid/seed-data/src/DemoData.res)
  draws everything from one random generator with a fixed seed, and names things by
  position: `cat-01`, `prd-001`, `cust-01`, `ord-001`. The same run twice gives the same
  commands. Delivery windows are the exception: they fall 1–21 days after the run date.
- **Steps, in order.** Categories → products and images → a deliberately rejected
  duplicate → catalog edits (repricing, new descriptions, a category rename and
  re-image, archived categories) → the supplier feed → customers (some move address)
  → wait until Ordering sees the products → orders (Express ones ship automatically)
  → ship most Standard orders → cancel some of the rest → deactivate some customers →
  archive and discontinue some products.
- **Checks at the end.** Every listed view holds at least one row (`verifyViews`),
  each demo account sees exactly its own orders (`verifyOwnerScopedReads`), and a
  summary table is printed.
- **Any refused command stops the run.** A half-seeded shop looks like a working one,
  so the seed stops at the first refusal rather than carrying on.

## Decisions

### D1. Keep `full` and `sample` as the first run; add one follow-up data set

The names `full` and `sample` are in the README and in anyone's `SEED_SET`, so they
stay. The new data set is `next`. It is one data set, not one per size: it sizes
itself from the shop it finds (D5).

### D2. The first run keeps one example of each change

Today the first run doubles as a smoke test: a price change reaching Ordering, a
product leaving the shelf, a cancellation. Moving all changes into follow-ups would
lose that. Keeping all of them leaves little for a follow-up to show.

So the first run keeps a **small** example of each change, and the bulk moves to
follow-ups:

| Step | First run today | First run after this plan | Follow-up run |
|---|---|---|---|
| Repricing | every 11th product | 1 product | a few, up and down |
| New descriptions | every 17th product | 1 product | a few |
| Category rename, re-image | 1 each | unchanged | — |
| Archived categories | from the fixture | unchanged | — |
| New products | all | all | 1–2 now and then, with images |
| Customers moving address | every 6th | 1 | a few |
| Customer deactivation | every 9th | 1 | now and then |
| Ship Standard orders | 80 % | see D6 | see D6 |
| Cancellations | a third of what is left | 1–2 | a few |
| Product retirements | from the fixture | 1 archived, 1 discontinued | now and then |

"Now and then" means the follow-up's random generator decides, so not every
follow-up does it.

### D3. A follow-up run is named by its run date

- **Ids carry the run date:** `cust-20260924-01`, `ord-20260924-001`,
  `prd-20260924-01`. They never collide with the first run's ids or with another day's.
- **The random generator is seeded from the run date.** Two different days give
  different activity; the same day gives the same commands.
- **Runs on the same day are numbered.** *(Revised 2026-09-17; first built as a
  refusal of the same day twice.)* The day's first run keeps `ord-20260924-001`; a
  second is run 2 with `ord-20260924-r2-001`, and so on. The number is one past the
  highest found among product, customer and order ids for that date, so a run that
  stopped before placing orders does not hand its number on. The random generator is
  seeded from the date and the number.

### D4. A follow-up reads the shop before deciding what to send

It reads, through the same GraphQL API (`Seed.Client.queryAllNodes`):

- products with their shelf status and current price, and categories;
- customers and whether they are active;
- orders with their lifecycle, shipping method and delivery window.

Everything it sends is chosen from what it read: new orders only for products still
on the shelf and customers still active; shipments and cancellations only for
orders still `Placed`; repricing from the current price, not the fixture's.

An **empty shop is refused**, the reverse of the first run's check: "run `full` or
`sample` first".

### D5. A follow-up sizes itself from the shop

Roughly one day's worth, relative to what exists:

- new orders: about 10 % of the current order count, at least 5;
- new customers: about 5 % of the current customer count, at least 1;
- repricing and new descriptions: 2–4 products each.

So a follow-up after `sample` stays small and a follow-up after `full` looks like the
same shop's day.

### D6. Delivery windows and shipping tell one story

Today a window is picked without looking at the shipping method, and shipping ignores
the window. An Express order placed today with a slot three weeks out, shipped the same
second, reads wrong.

The seed follows these rules. The shop itself does not enforce them — see "Not part
of this plan".

- **Pickup orders have no window.** Already true, and `PlaceOrder` now refuses one.
- **Express orders get a window 1–2 days after the run date.**
- **Standard orders get a window 3–21 days after the run date**, or none.
- **Shipping Standard orders:** a run ships the `Placed` Standard orders whose window
  starts within the next 3 days, plus about half of those without a window. The first
  run applies the same rule to its own orders, so most of them wait for a follow-up.
- **Cancellations** only pick `Placed` orders that are not shipping in this run.

The effect: a Standard order placed on day one ships on the follow-up closest to its
window, days later — the spread between "placed" and "shipped" that the lifecycle
trail is there to show.

### D7. Demo accounts get no new orders

A follow-up never places orders for the demo accounts, so their counts stay exactly
what the first run checks, and a follow-up can run the same check unchanged.

### D8. A follow-up checks what it added, not that views are non-empty

After a follow-up, every view is already non-empty. So it checks growth instead:
the Orders and Customers counts rose by what it sent, the retired products it named
show as retired, and the demo accounts still see exactly their orders. Views that
fill later on their own (notification deliveries) are reported, not checked.

## Steps

**1. Let the generators take a random generator and an id prefix.**
`DemoData.res` uses one module-level generator and position-based ids. Pass both in
(`~random`, `~idPrefix`), with the first run passing today's values.
*Check:* a test builds `full`'s products, customers and orders before and after the
change and compares them — identical.

**2. Let each step take the lists it acts on.**
The steps in `HybridSeedData.res` mostly already do; the ones that select from the
fixture internally (`DemoData.repricedProducts`, `movedCustomers`, `cancelled`, …) get
their selection passed in. No change in what the first run sends yet.
*Check:* the first run on a local store prints the same summary as before.

**3. Apply D6 to delivery windows and to the first run's shipping.**
Windows depend on the shipping method; `dispatchStandardBatch` ships by the window rule.
*Check:* `DemoDataTest` covers the window rule per method and the shipping selection.

**4. Trim the first run to one example of each change (D2).**
*Check:* `verifyViews` and the demo-account checks still pass on `full` and `sample`;
the README's description of the first run is updated.

**5. A reader for the current shop (D4).**
A small module that reads products, categories, customers and orders into plain
records, including retired rows (`includeRetired`).
*Check:* against a local store seeded with `sample`, it reads the counts the summary
printed.

**6. The `next` data set (D3, D5, D6, D7, D8).**
Refusals first (an empty shop), then generation from the reader's
records, then the steps in the first run's order, then the growth checks.
*Check:* unit tests for the generation on fixed input records (ids, sizes, the window
and shipping rules, no demo-account orders). Then locally, on SQLite: `sample`, then
`next` (passes), `next` again (refused before sending), and `next` with a different
run date (passes, ids differ). A run date can only be faked for this test, through an
environment variable the runner reads (`SEED_RUN_DATE`), because event times stay real.

**7. Try it on AWS and update the docs.**
On the `dev` stack: `shop:seed` with `full`, then `SEED_SET=next` on two later days.
Open the Ordering dashboard and the Orders calendar and check the spread by eye.
Document the follow-up in the example's README beside `full` and `sample`, including
that the local server must use SQLite (its default) for data to survive until the next
day.

## Progress

**2026-09-17 — steps 1 to 6 done; step 7 done locally, AWS remains.**

- **Step 1.** The generators take `~random` and an id prefix, and the order generator takes
  plain id lists and the demo-account customers of its first orders (`demoOrderCustomers`).
  Checked by dumping `full` and `sample` before and after: byte-identical.
- **Steps 2–4.** Each step in `HybridSeedData.res` takes exactly what it sends. Delivery
  windows depend on the shipping method; `DemoData.dueForShipping` and
  `DemoData.cancellations` apply D6 to both kinds of run. The first run keeps one example of
  each change. On `sample` it now ships 5 of 21 Standard orders and cancels 2.
- **Step 5.** `seed-data/src/ShopSnapshot.res`.
- **Step 6.** `seed-data/src/DemoFollowUp.res` decides the day's activity and
  `HybridSeedData.runFollowUp` sends it, as the data set `next`. Unit tests in
  `DemoFollowUpTest.res`. Tried on an isolated local platform: `sample`, then `next` (orders
  40 → 45), `next` again the same day (refused before sending), then `SEED_RUN_DATE` 2026-09-18
  and 2026-09-25 (45 → 50 → 55). Each run shipped orders earlier runs had left waiting, and
  the demo-account checks passed after every run.
- **Step 7, docs.** The example's README describes `next`.

**Where the build differs from the decisions above:**

- **The refusals needed a hook in the shared runner.** A refusal raised inside a data set's
  `seed` is reported as "the store is now half-seeded", which is untrue before anything was
  sent. `Seed.dataSet` gained an optional `preflight`, run where `probeViews` is checked, so a
  refusal reads "nothing was written".
- **Orders only use products in the shop's own currency.** The first local try stopped on
  `MixedCurrencies`: the supplier feed lists its products in USD, the generated catalog is in
  EUR, and a follow-up had drawn one of each into an order. The first run never met this,
  because it orders only generated products.
- **Follow-ups do not rename or re-image categories.** Renaming the same category back and
  forth reads as noise; left out rather than invented.
- **Ids:** `prd-<date>-01`, `cust-<date>-01`, `ord-<date>-001`. New customers' e-mail
  addresses carry the date too (`ada.almeida.20260924@example.com`), and their names continue
  the name pools past the customers already there.

**2026-09-17, later — several follow-ups per day.** The same-day refusal became run
numbers (D3). Tried on an isolated local platform: `sample`, then `next` three times on
one day — runs 1, 2 and 3, orders 40 → 45 → 50 → 55.

**Next:** step 7 on AWS — `shop:seed` with `full`, then `SEED_SET=next` on two later days, and a
look at the Ordering dashboard and the Orders calendar.

## Risks and open questions

- **`SEED_RUN_DATE` could be mistaken for backdating.** It only changes ids and the
  random choices, never the event times. Its name and help text must say so; if that
  is still confusing, keep it test-only.
- **Store size grows without end** if follow-ups run for months. Harmless for a demo
  store; a reset starts over.
- **A follow-up after a partial first run.** The reader sees whatever is there, and
  the checks in D8 are relative, so it works — but the demo-account check would fail if
  the first run stopped before placing their orders. That failure is the right answer.
- **Several follow-ups per day are allowed** (decided 2026-09-17). The cost: a run
  started twice by mistake is no longer caught — it adds a second batch, which is
  harmless for demo data.
