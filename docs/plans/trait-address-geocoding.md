# Plan: the AddressGeocoding trait

**Date:** 2026-08-30
**Repo:** reventless-core — a new package under `traits/`, and the `online-shop-hybrid` ordering
plugin it is extracted from.
**Status:** Proposed. Blocked only on the interference in §6.
**Builds on:**
[customer-address-backend-geocoding.md](./customer-address-backend-geocoding.md) — **the plan that
built this feature.** Steps 1–9 deployed and proven; its D3 round calibrated `0.97`/`0.01` against
the live Esri index after the shipped `0.8`/`0.1` declined correct addresses at a 1-in-4 rate. This
plan relocates what that one built; it re-decides nothing and restates none of it. ·
[domain-trait-extraction-online-shop-hybrid.md](./domain-trait-extraction-online-shop-hybrid.md)
(framework seams) ·
[conformance-test-kit.md](./conformance-test-kit.md) — check before building a suite harness;
different subject (storage-backend parity) but possibly a shared mechanism.

---

## 1. What the package owns, and what it does not

The line falls between **what a geocoder's reply means** and **how to graft that onto an aggregate
without corrupting its data**. Core owns the first; the trait owns the second.

**Stays in `spec/src/semantic/` — do not move:**

| | Where |
|---|---|
| `candidate`, `failure`, `search` (the port) | `Geocoding.res` — `Capabilities.t.geocode` names it |
| `assess`, `confidentMatch` (the confidence rule) | `Geocoding.res` |
| `defaultMinRelevance = 0.97`, `defaultAmbiguityMargin = 0.01` | `Geocoding.res` |
| `Geolocation.t` and `ofSearch` (reply → `Located`/`Unresolvable`, all five reason strings) | `Geolocation.res` |

⚠️ **This reverses the module split proposed in the companion plan's Part 2.** That part has the
policy half (`confidentMatch` and the two thresholds) moving out to the trait package. It should not:
`Geolocation.ofSearch` calls `Geocoding.assess` and threads both thresholds, and `Geolocation.t` is a
`@schema` semantic type rendered as a GraphQL union and read by the `Customers` read model. Moving
the policy would leave a core semantic type whose natural constructor lives in an optional package,
and would drag `GeolocationTest`/`GeocodingTest` out of core with it. The one principled objection —
that provider-calibrated numbers do not belong in a provider-neutral spec — is already answered in
the code: they are labelled arguments with defaults, so a differently-scoring provider passes its own
pair.

**The trait owns the graft rules** — the part that is hard to get right and easy to get wrong:

- the **`resolvedFrom` staleness token**: an answer for an address the subject has since changed is
  dropped, not applied
- the **redelivery guard**: the slice re-publishes on every heartbeat sweep until its TODO clears, so
  an unchanged answer must not append a duplicate event each pass
- **an outage is not a verdict**: `Unavailable` retries, `NoMatch` records a permanent fact
- the **stand-down**: a client that supplies address and point together must not be raced by the
  geocoder
- the **two-field state shape** (`location` + `locationResolvedFrom`) and its invariant, because
  three states — never asked, found, tried and found wanting — do not fit in one `option`

## 2. Shape

**Shape A: a scaffold plus a conformance suite.** The package holds no runtime policy — that is the
consequence of §1, not a shortfall. Contents:

1. **Scaffold templates** emitting into the host: the two `@noApi` commands, the three events, the
   two state fields, the guard arms in `decide`, the `evolve` arms, and the outbound translation
   slice.
2. **The conformance suite**, run by the host against its own graft.
3. **The host-contract declaration** — the five points of §3.

## 3. The host contract

Written over an **abstract subject type, not `string`**. `addressToResolve: event => option<string>`
would bind the vocabulary to a bare string, which the address/place semantic-type work retypes; an
abstract subject makes that a re-instantiation rather than a breaking change.

1. **Vocabulary + policy** — reason strings and the staleness rule (the confidence rule is core's).
2. **Binding surface** — trigger events (`Registered`, `AddressUpdated` in the specimen), the subject
   field, the entity id, the two target commands.
3. **Slice-set** — one outbound translation slice, keyed `{entityId}:{subject}`.
4. **Read-model contribution** — one `Geolocation.t` field.
5. **Required capabilities** — `geocode`.

## 4. The conformance suite

Three of the four assertions already exist as example GWTs in
`examples/online-shop-hybrid/ordering/tests/Customer/` and are transcribed, not authored:

| Assertion | Today |
|---|---|
| a superseded address's answer is dropped as stale | `Customer_GWT.res` |
| an unchanged answer is a no-op (redelivery) | `Customer_GWT.res` |
| an outage leaves the TODO pending; a no-match completes it with a verdict | `GeocodeCustomerAddress_GWT.res` |
| the stand-down | **not runtime-testable** — `collect` matches only the trigger events, so the pair-supplying event cannot reach the slice. Assert it as a *contract* check: the binding must never widen the consumed set |

## 5. Steps

- **G1** — create `traits/address-geocoding` as `@reventlessdev/trait-address-geocoding`, packaged
  per the open-source packaging rules: `.res`/`.resi` + in-source `.res.mjs` + `rescript.json`, an
  explicit `files` allowlist, `rescript` as a pinned peerDependency, never `lib/`.
- **G2** — write the host contract (§3) from the working implementation. Transcription, not design.
- **G3** — build the scaffold templates and the conformance suite (§2, §4).

  🔑 **Build the conformance runner as reusable machinery, and build only that.** A prior generality
  review across three worked competencies reached one recommendation: do **not** build a trait
  runtime or a generic scaffold engine — the third competency broke the two-specimen overlay rather
  than confirming it (into a writes-back / self-contained fork) and doubled the parameter count, so
  an engine written now would harden a fork before a fourth probe tests whether it is the only one.
  The single exception is the conformance runner: it is the one element every competency implements
  byte-identically, it is pure test code, and it is the artifact a marketplace listing's trust rests
  on. Write the host contract down as a type; leave the scaffolding hand-rolled for now.
- **G4** — **strip**: remove the woven-in slice, arms and guards from the example. Watch its GWTs go
  red. Never both implementations at once.
- **G5** — **transplant**: bind the trait, regenerate, run the conformance suite against the
  `Customer` graft.
- **G6** — delete the example GWTs the conformance suite now covers. One source of truth per guard.

**Exit:** event-level behaviour identical to today; conformance green; the package installs from its
own tarball into a scratch copy of the example and builds (the pack-and-install check — with a Shape
A package this is the only thing that proves the boundary is real, since there is no linked code).

## 6. Interference — none; cleared 2026-08-30

`customer-address-backend-geocoding.md` was the one workstream competing for these files, and it is
**complete**: all ten steps are deployed and verified on the live `alpha` stack. Nothing else is
writing to the geocoding path, so **G1–G6 can run straight through.**

What this plan takes from it, unchanged: the implementation itself, and D3's `0.97`/`0.01`
calibration against the live Esri index. Neither is re-decided here.

## 7. Risks

- **R1 — the specimen is one host.** Every rule here is validated against `Customer` only. The
  host-swap test is real only when a second host exists; until then, write the contract over the
  abstract subject (§3) and treat single-host validation as provisional.
- **R2 — do not generalise, in either direction, yet.** Two temptations: a resolver primitive (this
  shape is the reusable middle of translation, currency conversion, enrichment and OCR), and a
  generic scaffold engine. Both are premature for the same reason — see G3. Write the contract down
  as a type, build the conformance runner, hand-roll the rest.
- **R4 — this competency writes back to its host; not all do.** The graft here emits `@noApi`
  commands into the `Customer` aggregate. At least one other competency is host-side-effect-free and
  writes nothing back. Carry the write-back posture as an **explicit flag** on the host contract from
  the first version — a contract that assumes write-back because the first specimen had it will
  mis-model the next one.
- **R3 — deleting example GWTs (G6) removes tests before the replacement is proven.** Do G6 only
  after G5 is green, in a separate commit, so the deletion is revertible on its own.
