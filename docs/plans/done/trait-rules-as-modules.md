# Plan: trait rules as modules — retiring the string templates

**Date:** 2026-08-31
**Status:** Done 2026-08-31. F1–F6 landed against both shipped traits; the held domain-traits docs
page is published against the final shape.
**Builds on:** [trait-address-geocoding.md](./trait-address-geocoding.md) ·
[trait-file-attachment.md](./trait-file-attachment.md) ·
[domain-trait-extraction-online-shop-hybrid.md](./domain-trait-extraction-online-shop-hybrid.md)

## Why

The shipped traits carry their rules as text: `templates/*.res.tpl` fragments a host applies by
string replacement. The rules' only executable form is each host's pasted copy — the two attachment
hosts carry the same guards byte-similar, and nothing but the conformance suite stops a copy from
drifting. Functors and first-class modules are how everything else in this framework composes; the
traits' own conformance suites are already functors. The rules should be too: **compiled once in the
trait, called by the host**. A per-trait rule module is ordinary trait content — not a generic trait
runtime or scaffold engine, which remain out of scope.

## The boundary (what stays a copy)

The host's **spec surface** cannot come from a functor and stays host-authored under either shape:
variant constructors (`type command` / `type event` are closed; two hosts in one plugin need
distinct names), the ppx/generator-read annotations (`@schema`, `@transition`, `@authorize`,
`@noApi`, store-from-field-name, DCB tag inference — all read off the host's own source), and the
host's policy (which lifecycle states refuse, retry counts). That residue is ~20–40 declarative
lines per host. Everything below it — `decide` guard logic, `evolve` folds, projection helpers —
moves behind the module boundary.

One rule for aggregate hosts: **trait types in transient state, host types in persisted state.**
Aggregate state is snapshotted; a trait-owned record embedded there turns every trait release that
reshapes it into a snapshot migration. The trait operates on a per-call view built from host-owned
fields (`Customer` keeps `location` + `locationResolvedFrom`). StateChangeSlice state is refolded
per decision and never stored, so the attachment hosts may embed the trait's state type directly.

## Steps

- **F1 — `FileAttachment_Set`** in `traits/file-attachment`: `type t`, `empty`, `op`, `fact`,
  `decide: (t, op) => result<option<fact>, [#NotAttached]>`, `evolve`, `effectivePrimary`. The
  set's rules stated once.
- **F2 — hosts delegate.** `ProductImages_Behavior` / `CategoryImages_Behavior` become their own
  refusals plus constructor↔op/fact mapping over an embedded `Set.t`; the two `Projections` call
  `effectivePrimary` instead of carrying their own fallback. Conformance (14 × 2) and host GWTs must
  stay green unchanged — they are the migration's verification, so they are not edited in this step.
- **F3 — `AddressGeocoding_Guards` + `AddressGeocoding_Translate`** in `traits/address-geocoding`:
  the staleness/redelivery/verdict guards over a transient `resolution` view, and the slice's
  `translate` / `onExhausted` bodies with constructor callbacks. `Customer_Behavior` and
  `GeocodeCustomerAddress_Translation` delegate. Conformance (13) green unchanged.
- **F4 — templates shrink to spec fragments.** What remains is the declarative surface only:
  constructor declarations with their annotations and comments, the state fields, a delegating
  behavior of a dozen lines, projection arms that call the trait. Rename `templates/` →
  `spec-fragments/` in both packages (update `files` allowlists and READMEs); the fragments must
  keep the comments that explain load-bearing annotations, since the rule code no longer sits
  beside them.
- **F5 — packaging consequences.** The trait is now a runtime dependency: its `.res.mjs` is
  imported by host output and must resolve wherever the host's handlers run. Verify with the
  existing `pnpm run check:traits` (the scratch host now exercises the runtime import) and one
  hybrid platform-local flow run. Rule changes become semver-relevant behavior changes for hosts;
  note this in both trait READMEs.
- **F6 — docs.** Finalise the held domain-traits App Guide page against the final shape ("the rules
  are a module you call; the types are yours"), and refresh both trait READMEs' grafting sections.

Order: F1→F2 first (the richer specimen), F3 after, F4–F6 last. One commit per trait migration
(F1+F2, then F3), F4–F6 together.

**Exit:** no rule logic in any fragment; both conformance suites and all host GWTs green without
edits; `check:traits` green; lifecycle and GraphQL goldens unchanged (the spec surface does not
move); docs page committed.

## Outcome

Every exit condition met. `FileAttachment_Set` carries the set's `op`/`fact`/`decide`/`evolve` and
the `primaryOf` fallback both the decision side and the two projections now call;
`AddressGeocoding_Guards` carries the four verdicts and `AddressGeocoding_Translate` the geocoder
call plus `exhaustedReason`. The four host bodies became mapping and refusal only. Both conformance
suites (14 × 2 and 13) and every host GWT stayed byte-identical and green — 3925 tests across 368
suites, zero compiler warnings — and the GraphQL and lifecycle goldens did not move, which is the
evidence that the spec surface did not.

Two things the plan did not anticipate:

- **`Attach`/`Attached` carry the caption.** Keeping it off them left the attach arm the one place a
  host could not map fact→event mechanically. Both shipped hosts' consumed event drops `altText`, so
  they pass `None` and behave exactly as before; a host whose consumed event kept it would fold the
  caption at attach, which is the more correct reading anyway.
- **`primaryOf`, not `effectivePrimary`, is what a projection calls.** A read model holds rows, not a
  `Set.t`, so the rule is stated over `(~chosen, ~attached)` and `effectivePrimary` is its one-line
  specialisation for the fold. Stating it only over `t` would have left the projections with a copy.

The aggregate's transient-state rule cost more ceremony than the slice's embedded one: `Active`'s
inline record cannot escape its constructor, so `Customer_Behavior` builds the trait's view through a
three-argument `resolution` helper at each call site. Four `decide` arms replaced eight, and the
subtle half is gone from the host — but this is the shape R3 warns about, and a future aggregate host
should expect it rather than be surprised by it.

Verified live on `platform-local` beyond the suites: the attachment trait through `CategoryImages`
(idempotent re-attach and repeated caption both `eventCount: 0`, the standing-in primary a no-op,
`CategoryImageNotAttached` for a ref not in the set, and the view falling back to the first attached
after the chosen primary was removed), and the geocoding trait through `Customer` (`UpdateAddress`
with the same address and a repeated supplied pair both `eventCount: 0`, the view carrying
`GeolocationLocated`). `Catalog_AddProduct` rejects `CategoryNotFound` against the in-memory backend —
reproduced on the unchanged code, so it is unrelated to this migration and left where it is.

## Risks

- **R1 — behavior drift hidden by the refactor.** Mitigation is the step order: the suites are the
  gate and are frozen during F2/F3; any assertion edit during migration is a red flag, not a fix.
- **R2 — the lifecycle harvest.** Host GWTs stay literal and host-authored (the sidecar emitter
  reads literals); nothing in this migration may move `@transition` evidence into conformance
  functors.
- **R3 — a future aggregate-hosted attachment trait** would meet the transient-state rule head-on;
  the accessor indirection is the answer, and if it ever costs more clarity than copied arms did,
  that is the signal to revisit — per host, not by reverting the trait.
