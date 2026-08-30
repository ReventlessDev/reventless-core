# Plan: the product attachment set, and the FileAttachment trait

**Date:** 2026-08-30
**Repo:** reventless-core — the `online-shop-hybrid` catalog plugin, one capability seam, and the
trait package that comes out of it.
**Status:** Proposed. Part A has no framework dependency and can start immediately; Part B is gated
on one seam and one decision.
**Builds on:**
[done/upload-release-path.md](./done/upload-release-path.md) (mint and release behind the platform
GraphQL API) ·
[done/upload-pending-claim-and-expiry.md](./done/upload-pending-claim-and-expiry.md) (mint-pending →
claim-on-commit → expire-what-stays-pending; **this is the disposal mechanism, and it already
exists**) ·
[done/product-image-optional-storage-ref.md](./done/product-image-optional-storage-ref.md) ·
[domain-trait-extraction-online-shop-hybrid.md](./domain-trait-extraction-online-shop-hybrid.md)
(the framework seams this workstream needs)

---

## 1. The split this plan makes

The competency has been carried as one blocked unit. It is two, and only the second is blocked:

| | Reads stored bytes? | Gated on |
|---|---|---|
| **Part A — the attachment set**: multiple images per host, primary selection, alt text, attach/remove as domain facts, gallery UI | no | nothing |
| **Part B — scan and retention**: scanning an uploaded file, disposing of removed ones | yes | one capability seam + one decision (§4) |

Everything in Part A is domain state and presentation. Nothing in it opens a file, so nothing in it
needs the object store's plugin door. **Part A can be built and extracted today.**

## 2. What exists today (verified 2026-08-30)

| Piece | State |
|---|---|
| `UploadableImage.t` semantic type; store derived from the field name | shipped, `spec/src/semantic/UploadableImage.res` |
| `ImageRef.t` for images the platform does not own | shipped |
| `Offload` — inline-or-reference, content-addressed | shipped, `spec/src/semantic/Offload.res` |
| Mint / release / presign behind the platform API | shipped |
| Mint tags `reventless:pending=true`; a claim component strips it on a committed event carrying the ref; a lifecycle rule expires what stays pending | **implemented**; the lifecycle rule ships **off** until a deployment names the store |
| `GalleryView`, gallery auto-mode, `StatusBadge` | shipped in the UI kit |
| Attach/replace as guarded domain facts, for **two** hosts (`productImages`, `categoryImages`) | shipped — `ChangeProductImage`, `ChangeCategoryImage` |
| Object-store accessor on `Capabilities.t` | **absent.** The record has exactly one field, `geocode`; `Offload.resolve(~fetch)` has no production caller |

Two corrections to carry forward, both found by reading the code rather than the docs:

- **`Capabilities.res`'s own docstring is wrong.** It states that "the object store already works
  this way, with `Upload_Presign` on one side and an injected `Offload.resolve(~fetch)` on the
  other". The client half is true; the plugin half is not. Fix the docstring in whichever part
  lands first.
- **Byte disposal is not an open question.** It was decided and built on 2026-08-02: tag at mint,
  claim on commit, expire what stays pending. What remains is narrower and is stated in D2.

## 3. Part A — the attachment set (no framework dependency)

Each host today carries a single overwritable `productImage: UploadableImage.t`. The gap is that one
picture is not a set.

- **A1 — model the set as domain facts.** Replace the single field with an ordered attachment set on
  `Product`: attach, remove, set-primary, set-alt-text. `ChangeProductImage`'s existing guards are
  the template — it already has the lifecycle edge (`@transition([Listed, Archived])`, refused once
  `Discontinued`) and an idempotency guard. Keep both, per member.
- **A2 — do the same for `Category`.** `categoryImages` is a second host of the same shape and comes
  nearly free. Two hosts is what makes the host contract testable rather than asserted: a trait's
  policy must survive a host swap, and this is the swap.
- **A3 — read-model contribution.** Extend `Products` and `Categories` to surface the set, the
  primary, and each member's alt text. Attachment status becomes a domain-visible fact rather than
  an absence.
- **A4 — gallery UI.** `GalleryView`, the auto-mode and `StatusBadge` exist, so this is wiring:
  gallery with primary selection and alt-text entry, replacing the single-image control.
- **A5 — extract.** Strip the woven-in implementation, watch the example fail its own GWTs, then
  bring it back as a consumption of `@reventlessdev/trait-file-attachment`. Never both
  implementations side by side.

Exit: products and categories carry multi-image sets with a primary and alt text; the gallery
renders them; the trait's conformance suite is green against both hosts.

## 4. Part B — scan and retention (gated)

🚨 **Part B requires two capabilities, and one of them does not exist.** This competency is the first
whose required-capability list has more than one entry, and the two are in different states:

| Required | State |
|---|---|
| `ObjectStore({plugin, store})` | **half-provisioned.** The client door is real — bucket, per-prefix pending-expiry lifecycle, `~protect`, presign, and the generated `PlatformCapabilities.res` entry. The **plugin door is unwired** |
| `Scanning` | **does not exist.** Verified 2026-08-30: `Platform.capability` has exactly two arms, `ObjectStore` and `Geocoding`. No arm, no provisioner, no port, no local implementation |

`Scanning` is plugin-door-only — no client sends a file to be scanned interactively — which makes it
the second concrete instance of the capability model's open question about whether every capability
needs both doors.

- **B1 — wire the object store's plugin door.** `Capabilities.t` gains an object-store accessor
  shaped to what `Offload.resolve` already takes: `fetch: string => promise<string>`. Platforms fill
  it — `aws` from S3, `local` from `LocalObjectStore` — and `Capabilities.none` gets an
  `Unavailable` arm, matching how `geocode` is already handled. A near-exact copy of the geocode
  shape, which is what makes it small.
- **B2 — build the `Scanning` capability**: the `Platform.capability` arm, a provisioner, the port,
  and a local implementation. This is capability-layer work, larger than B1, and it is the real gate
  on Part B.
- **B3 — resolve D2 (below), then model removal's byte consequence.**
- **B4 — the scan slice.** An outbound slice that reads the uploaded bytes through B1's accessor and
  records a trust verdict as a domain fact. Writable only once B1 and B2 exist.

## 5. Decisions

**D1 — the trait's shape, decided against the built code, not in advance.** The competency has been
provisionally typed as a trait-owned slice-set keyed by the host's entity tag. That was chosen before
`UploadableImage.t` and `Offload` shipped. Re-test it at A5: if the set is expressible as scaffolded
host state plus a conformance suite, the simpler shape wins. Deciding this before A1–A4 exist is
guessing.

**D2 — what happens to the bytes when an attachment is removed.** The prior design pass already made
the top-level call — **defer byte deletion to the store's lifecycle configuration and keep only the
domain fact** — and noted its limitation: a trait cannot today request a *mutating* capability
operation, because the object store's plugin door is read-only (`~fetch`) and a `Task`'s only lever
is `PublishCommands`. What follows refines that call with a concrete mechanism rather than reopening
it; the question is narrower than "how do we delete objects".

The existing mechanism collects objects **nobody ever committed a reference to** — minted, tagged
pending, never claimed. An attachment that *was* committed and is *then removed* from the set has
already had its tag stripped, so it sits outside the lifecycle rule permanently. Removal orphans it.

Two options:

- **Re-tag on removal (recommended).** The claim component learns the inverse: a committed event that
  drops a storage ref re-applies `reventless:pending=true`, and the existing lifecycle rule collects
  it on the same schedule. No new mechanism, no new failure mode, and it preserves the stated safety
  direction — every path still fails toward *keeping* the object.
- **An explicit disposal operation on the object-store capability.** Immediate and precise, but it
  puts deletion in a slice's hands, which is the thing the tag design deliberately avoided: a
  disposal call is a decision made once, where a tag is a decision the lifecycle rule keeps
  re-checking.

Recommend the first. Note that neither is needed for Part A — an orphaned object is tolerable, and
removal is modellable as a domain fact without any byte consequence at all.

## 6. Risks

- **R1 — retiring the single field is a breaking event-log change.** `ProductAdded`,
  `ProductImageChanged` and `ImportProduct` all carry the old shape. This needs an event-log wipe,
  and it must ride an already-pending one rather than triggering a second.
- **R2 — the lifecycle rule is still off.** It ships disabled until a deployment names the store, so
  nothing expires today regardless of D2. Turning it on is a deployment step, not a code change, but
  it has to actually happen or the retention half of this plan is inert.
- **R3 — two hosts, one trait.** `productImages` and `categoryImages` are similar enough that a
  trait could accidentally encode product-specific assumptions and still pass on both. Write the
  host contract over the abstract host, and have the conformance suite run against both.
