# Plan: Stop Plugin-Definition Schema Evolution From Wedging a Plugin

**Status**: Phases 1a, 1b, 2, 3, 4 implemented 2026-08-01 — full build warning-free, 2540 tests green. `requiredStoreDeclaration.annotation` has since been made `js_nullable`, so no stored payload needs a fabricated value any more and the rule now holds for the field that motivated it. Phase 5 not started; its blocking unknown is **settled** (measured against real stored payloads — see Phase 5), leaving it a value judgement rather than an open question. Two deviations from the plan as written, both recorded in-place below. One open item: Phase 2's runtime behaviour is unverified until a deploy.
**Analysis**: [plugin-definition-schema-evolution-wedge.md](../analysis/plugin-definition-schema-evolution-wedge.md)
**Prior occurrence**: [platform-infrastructure-in-plugin-list.md](done/platform-infrastructure-in-plugin-list.md) — same class, fixed 2026-07-11 with schema-migration-on-read; that fix has a blind spot this plan closes.

## Problem

Adding a **required scalar** field to any type reachable from `pluginDefinition` makes every
already-stored lifecycle event undecodable. The Plugin aggregate replays its own log on every
command, so one stale event freezes `Heartbeat` / `Redetect` / `Connect` for that plugin
permanently. `06fb5d671` (`annotation: string` on `requiredStoreDeclaration`) did exactly this to
`Catalog` on 2026-07-30; it went unnoticed until 2026-08-01, surfacing as an empty product list and
a `SubSelectionRequired` GraphQL error on an unrelated field.

The existing `fillMissingDefaults` healer absorbs an absent field only when its schema is a
nullable union, an array, an enum, or an object. A bare `string` / `number` / `boolean` falls through
and stays `undefined`. That rule is real, load-bearing, unwritten, and unenforced.

Full walk-through, evidence, and the options considered are in the analysis.

## Goals

- A required-scalar addition to a persisted structure type fails **in CI**, naming the field, before it can reach a deploy.
- A plugin that dead-letters the same command repeatedly produces a signal a monitoring backend can consume.
- Replay of the lifecycle aggregate does not throw on a metadata-only field addition.
- No change to the strict-decode fast path: current messages decode byte-for-byte as they do today.

## Non-goals

- Framework-level alerting. `Monitoring.notify` is deliberately a no-op seam
  ([Monitoring.res](../../reventless/core/src/adapter/Monitoring/Monitoring.res)) — "monitoring/alerting itself is deliberately NOT a framework concern". This plan restores the *signal*; consuming it stays an extension's job.
- General event upcasting / versioned event schemas. Out of scope; the lifecycle log is a
  registration ledger a deploy can reconstruct, which is why a wipe was an acceptable recovery.
- Migration of existing stored payloads. Alpha wipe over migration code stands.

---

## Phase 1 — Tripwires in CI

The highest value-per-effort work, and independent of everything else.

### 1a. Frozen-payload compatibility corpus (primary)

**Why the existing tests missed it.** `MessageTest.res:96-240` already has two tolerant-decode
cases, but they build the payload from a ReScript `pluginDefinition` literal and then strip keys.
That literal is written against the *current* type, so it recompiles with every schema change and
can only test the fields the author remembered to strip. It is structurally incapable of catching
the next addition.

The corpus must therefore be **frozen JSON that never regenerates from the current types.**

- Add `reventless/core/tests/fixtures/plugin-lifecycle/` holding real historical event payloads as
  JSON, one file per shape-generation, named by the date/version they were written under
  (`2026-07-30-versionconnected-alpha168.json`, …).
- Seed it from the recovered `Catalog` stream — including the exact `VersionConnected` at position
  69 that caused this incident. That payload is the regression test: it must decode.
- Load them through a companion `.mjs` that exports `array<{name, json}>` (bound with `@module`),
  rather than `fs` or JSON import attributes — deterministic, no Node/Jest ESM friction.
- New `PluginLifecycleCorpusTest.res` in `reventless/core/tests/`: for each fixture, assert
  `Message.decode(json, PluginSpec.eventSchema)` does not throw.
- **Never regenerate the corpus.** Add a README in the fixture dir saying so, and that new entries
  are *appended* when a payload shape changes.

A required-scalar addition then turns into a red build naming the field and the path.

**Implemented.** [`PluginLifecycleCorpusTest.res`](../../reventless/core/tests/plugin/PluginLifecycleCorpusTest.res)
over [`tests/fixtures/plugin-lifecycle/`](../../reventless/core/tests/fixtures/plugin-lifecycle/)
— 5 payloads recovered from the deployed `Catalog` stream, spanning four shape generations,
loaded through `corpus.mjs` and decoded exactly as replay does (`combineMessage` → `decode`).
Verified in both directions: before Phase 3 the two incident fixtures failed naming
`["_0"]["structure"]["requiredStoreDeclarations"]["0"]["annotation"]`; after it, all 6 pass.

**Scope correction after Phase 3 landed**: the corpus no longer catches a required-scalar
addition, because the healer now invents a value and the payload decodes. It still catches
what healing cannot absorb — a changed field type under stored data, `bigint`, real
corruption. Goal 1 therefore rests on 1b, which is why 1b moved from optional to done.

### 1b. Declaration-site shape guard — **implemented** (was: decide during implementation)

A test that walks the current `pluginDefinitionSchema` and asserts every field is nullable, array,
enum, or object — with an explicit allowlist of the required scalars that legitimately exist today
(`id`, `name`, `version`, `eventCollector`, …).

Catches the mistake at the moment a field is declared, before any event with the old shape needs to
exist. The allowlist is a golden file that only changes when someone adds a scalar, which is exactly
the moment we want a deliberate conversation.

*Trade-off*: a second guard to maintain, and the allowlist is noise on legitimate changes. 1a alone
is sufficient for correctness; 1b buys an earlier, more legible failure. Recommend implementing 1a
first and judging 1b against how noisy the allowlist actually looks.

**Judged and implemented.** The list is 81 entries — a snapshot file, one line per field, that
changes only when someone adds a required scalar. Acceptable, and no longer optional: after
Phase 3 this is the only thing enforcing Goal 1 in CI.

[`PluginDefinitionRequiredScalarsTest.res`](../../reventless/core/tests/plugin/PluginDefinitionRequiredScalarsTest.res)
compares [`pluginDefinitionRequiredScalars.txt`](../../reventless/core/tests/plugin/pluginDefinitionRequiredScalars.txt)
against a walk of the live schema; the reflection lives in `pluginDefinitionScalars.mjs` rather
than `%raw`, per the repo rule on untyped reflection. Verified in both directions by perturbing
the golden file — the failure reports `ADDED` / `REMOVED` by path.

**Collector bug, found by using it (2026-08-01).** The first version walked into the non-null arm
of a `T | null` union, so a `js_nullable` scalar was reported exactly like a required one. The
guard would then have gone red on the very shape the rule tells authors to reach for, and the
first list carried ~30 such false positives. Fixed to skip *scalar* arms of a nullable union while
still descending into *object and array* arms — because when an old payload happens to carry a
nullable parent, a scalar added inside it does still have to be invented. That distinction is not
academic: it is exactly how `requiredStoreDeclarations[].annotation`, a required string inside a
nullable array, froze a plugin. 111 entries → 81.

**Resolved: `annotation` is now `js_nullable`.** The field that caused the incident no longer
forces a fabricated value. `CapabilityManifest.provenance` and `PlatformCodegen.provenance` — the
two places the value travels onward to — already declared it optional, with a rationale identical
to the rule this plan wrote down ("a reader that cannot say what the source says omits the claim
rather than inventing one"); the event-log copy was the lone hold-out, and the one that broke.
The producer always emits `Some`, so `capabilities.json` output is unchanged. Every corpus fixture
now decodes with **zero** invented scalars — the incident payloads heal purely from schema-derived
defaults.

The corpus could now additionally assert "nothing was fabricated". Not added: it needs a reporting
variant of `parseJsonTolerant`, and the golden list already catches the same trigger at the
declaration site, so the second net would be new API surface for little added reach.

## Phase 2 — Restore the dead-letter signal

Today [`Util_DeadLetterQueue.res:48`](../../reventless/aws/src/util/Util_DeadLetterQueue.res#L48) is
a consumer that logs and returns success, so SQS deletes the message. **DLQ depth is pinned at 0**,
the Lambda `Errors` metric stays 0, and both standard signals are structurally unable to fire. 217
dead-lettered `Heartbeat` commands passed through it in the 20 hours before recovery.

Options:

- **(i) Remove the consumer.** Messages accumulate; depth becomes a real metric; retention drops them
  after the configured window. Simplest, restores the conventional signal, and the payloads stay
  inspectable in the queue itself. Loses the CloudWatch-log copy.
- **(ii) Keep it for logging, then re-raise.** Restores both depth and `Errors`. Risks a retry loop
  on the DLQ itself (no further redrive target), costing invocations indefinitely.
- **(iii) Log, delete, and emit a metric.** Keeps today's behaviour and adds an explicit signal, but
  puts provider-specific alerting plumbing into core, against the Monitoring seam's stated position.

**Recommend (i)**, with the `DeadLetterSink` `Monitoring.notify` call kept as-is — a backend that
wants log copies or alarms attaches them there, which is what the seam is for. Confirm the retention
window on both `DeadLetterQueue` and `FIFODeadLetterQueue` is deliberate while touching this.

**Deviation — implemented (ii), not (i).** Reading the file invalidated the recommendation: the
consumer Lambda *is* the subject of the `Monitoring.notify(~kind=DeadLetterSink)` call, which
`Monitoring.res` documents as its second provisioning site. Removing it would have deleted the
only execution unit that seam ever emits for that kind, leaving a backend with nothing to attach
an alarm to — the opposite of this phase's goal. (i) also carried a much larger deploy diff: a
Lambda, a role, two event-source mappings and two queue policies destroyed on the next `pulumi up`.

(ii) is a three-line change to `entryPointCode`: log, then throw. The message stays on the queue
(depth becomes real) and `Errors` goes non-zero, so both conventional alarm subjects work and the
seam site survives. The retry storm I worried about at plan time is bounded by retention and costs
~10 ms per redelivery on a queue that is empty in normal operation.

Retention was inherited, not chosen — now stated explicitly at 14 days (the maximum), so a dead
letter cannot expire over a long weekend before anyone reads it.

`reventless-aws` suite green (398 tests), including the import-time-resource suites that are
sensitive to this module's shape.

## Phase 3 — Close the healer's blind spot

In [`Message.res`](../../reventless/spec/src/types/Message.res#L165), extend `fillMissingDefaults`
to fill an absent scalar with its type's zero (`""` / `0` / `false`).

- Keep the existing structure exactly: strict decode first, fill+retry only on failure, re-throw the
  **original** error when the fill does not resolve it.
- **Log loudly when a scalar fill is what rescued the decode.** This is the difference between a
  guard and a silent data-fabricator: an empty string is a plausible `annotation` but a wrong
  `store`, and a genuinely truncated payload would now decode where before it threw. Healing must be
  visible in logs so it can be found and corrected, not absorbed.
- Add corpus entries (Phase 1a) for the scalar-fill case so the behaviour is pinned.

*Optional cleanup while here*: `fillMissingDefaults` is `%raw` inside a `.res` file. Moving it to a
companion `.mjs` bound via `@module` matches the repo rule on untyped reflection. There is existing
`%raw` precedent in `reventless/spec/src` (`PackageVersion.res`, `Codegen.res`), so this is
alignment rather than a fix — take it only if the diff stays small.

**Implemented.** `fillMissingDefaults` gained a `scalarDefault` arm (`""` / `0` / `false`, or the
`const` when the schema pins one) and threads a path through the walk; `bigint` is excluded on
purpose, having no JSON form. It now takes a `scalarFills` out-parameter, and `parseJsonTolerant`
emits a `Console.warn` naming every invented path and value:

> `[reventless] decoded a stored message by inventing 4 missing scalar field(s): ._0.structure.requiredStoreDeclarations[0].annotation := "", … A required scalar was added to a persisted type after this message was written; the value above is fabricated, not recovered. Prefer a js_nullable (T | null) field.`

Schema-derived heals stay silent — only invented values are worth a line. The `%raw` → companion
`.mjs` move was **not** taken: the diff was already substantial and the two changes are unrelated,
so bundling them would have obscured the behavioural one. The new reflection added in Phase 1b does
follow the rule (`pluginDefinitionScalars.mjs`).

## Phase 4 — Write the rule down

The rule that was unwritten and got violated:

> A field added to a type reachable from `pluginDefinition` must be nullable (`T | null`), an array,
> an enum, or an object — never a bare required scalar. Stored events predate it, and only those
> shapes can be healed on read.

- Put it on the `requiredStoreDeclaration` / `pluginStructure` doc comments in
  [`Plugin.res`](../../reventless/spec/src/components/Plugin.res), where an author is already reading.
- Cross-reference the corpus test so the reason is discoverable from the failure.

Phase 4 is documentation and does not stand alone — it is what makes Phase 1's red build legible.

**Implemented** as a doc comment on `pluginStructure` in
[`Plugin.res`](../../reventless/spec/src/components/Plugin.res), stating the healable shapes, the
consequence of a scalar (a fabricated value plus a warning), and where the guards are — plus a
short note on `requiredStoreDeclaration` naming `annotation` as the worked example.

## Phase 5 — (gated) Decode the definition lazily

The structural fix: type the definition inside the *event* as opaque `JSON.t`, and decode to the
typed record only at the projection and API boundaries where it is read. Replay then cannot fail on
a metadata field, and a bad payload degrades one plugin's manifest instead of freezing its lifecycle.

`decide` / `evolve`
([PluginBehavior.res:127-233](../../reventless/core/src/plugin/lifecycle/PluginBehavior.res#L127-L233))
only read `def.version`, compare definitions, and carry them forward — so the full typed decode on
every replay buys nothing the aggregate uses.

**Risk to settle before committing to this**: the idempotency branch at
[PluginBehavior.res:153](../../reventless/core/src/plugin/lifecycle/PluginBehavior.res#L153)
(`definition == def ? Ok([]) : …`) would compare raw JSON instead of decoded records. Absent-vs-`null`
asymmetry between a freshly encoded definition and a stored one could make equality spuriously false
and re-emit `VersionConnected` on every deploy — noisy, not incorrect, but it must be checked with a
real payload pair before this phase is scheduled.

**Settled 2026-08-01 — real, bounded, self-correcting.** Measured against actual stored payloads:
the live `Catalog@1.0.0-alpha.173` event, and the three `VersionConnected` fixtures in the corpus.

| stored event was written… | today (decoded `==`) | Phase 5 (raw `==`) |
|---|---|---|
| under the current schema | equal | **equal** |
| under an older schema | equal (healing normalizes both sides) | **not equal** |
| …and again, after one re-emit | equal | **equal** |

So the asymmetry is real but does **not** re-emit on every deploy, as feared. `Primitive_object.equal`
is key-order insensitive (only `JSON.stringify` differs), so the sole source of inequality is a stored
event genuinely older than the current shape — absent keys where a fresh encode writes `null`, or a
healed value where the stored payload had none. The first `Connect` after a schema change emits one
extra `VersionConnected`; that event is written in the current shape, and every deploy after it
compares equal again.

**Cost of Phase 5, quantified: one redundant `VersionConnected` per plugin per schema change**, which
is also a re-projection of a row that was going to be re-projected anyway. That is a much smaller
price than the plan assumed, and it does not block scheduling. It can be removed entirely by
comparing `decode(stored) == decode(incoming)` at that one branch instead of raw JSON — the decode
stays out of the replay path, which is the point of the phase, and only the idempotency check pays it.

**Gate**: do Phases 1–4 first and see whether the tripwire fires again. If `Plugin.res` keeps
changing at the current rate (6 schema-affecting commits in ~5 weeks), Phase 5 earns itself. If
Phase 1 turns the failure into a routine red build that authors fix in a minute, the structural
change may not be worth its blast radius.

Status of the gate: the blocking unknown is resolved (above), so this is now purely a
value judgement waiting on evidence — how often the Phase 1b list actually changes, and whether
authors find the red build a one-minute fix or a recurring irritation. Nothing further to
investigate before scheduling it.

Option E from the analysis — stop persisting derived metadata as event payload at all — stays
documented and unscheduled. It is the correct end state; Phase 5 is most of its benefit for a
fraction of its reach.

---

## Sequencing

1. **Phase 1a** — corpus + test. No runtime change, catches the class.
2. **Phase 2** — dead-letter signal. No runtime change to the happy path; independent of 1.
3. **Phase 4** — the rule, written where it is read. Trivial; pairs with 1.
4. **Phase 3** — healer extension. Runtime change, wants 1a in place first so its behaviour is pinned.
5. **Phase 1b** — judge after 1a lands.
6. **Phase 5** — gated; re-evaluate after the above have been in place for a few schema changes.

Phases 1–4 are independently landable and independently valuable; none blocks another.

## Verification

- **Phase 1a**: with `annotation` reverted to required and the incident payload in the corpus, the
  new test must fail naming `["_0"]["structure"]["requiredStoreDeclarations"]["0"]["annotation"]`;
  with the current schema it must pass. Both directions asserted before the plan step is closed.
- **Phase 2**: a deliberately poisoned command must leave `ApproximateNumberOfMessages > 0` on the
  DLQ rather than a `console.error` and a zeroed depth.
- **Phase 3**: strict-path output unchanged for every corpus fixture that already decodes (assert
  equality against the current decode, not just absence of a throw); scalar-fill path emits its log line.
- **Phase 5** (if scheduled): a redeploy with an unchanged definition emits **no** `VersionConnected`.

### Result (2026-08-01)

- Root `pnpm run build` warning-free; `pnpm exec jest` 286 suites / 2521 tests green.
- Phase 1a verified both directions (red before Phase 3 naming the field, green after).
- Phase 1b verified both directions by perturbing the golden file (`ADDED` / `REMOVED` reported).
- Phase 3's strict fast path is untouched by construction — the fill runs only after a throw.
- Phase 2 verified by unit suites only. The runtime claim (a dead letter now raises depth and
  `Errors` instead of vanishing) needs a deploy to confirm and is **not** yet observed on AWS.

**Unrelated pre-existing failure, left alone**: `pnpm run test:projects` fails with
`reventless-seed: discovers 0 suites`. `448f88714` deleted that package's tests and HEAD tracks
none, so the check is red independently of this work. Fixing it means either restoring tests or
adding a `KNOWN_EMPTY` entry per [ci-unit-test-coverage-gap.md](ci-unit-test-coverage-gap.md) —
a call for whoever owns that gap, not this plan.
