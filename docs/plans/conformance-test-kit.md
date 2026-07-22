# Plan: Backend conformance test kit (`reventless-conformance`)

**Status**: Draft (2026-07-03)
**Nature**: feature plan. One new published package
`reventless/conformance` (`@reventlessdev/reventless-conformance`,
Apache-2.0) holding backend-parameterized behavioral suites; `reventless-local`
and `reventless-aws` become its first two consumers; one packaging hygiene fix
in `reventless-local`.
**Relation**: `docs/plans/postgres-storage-adapter.md` F1/F2 anticipates this
kit ("keep scenarios parameterized over the storage makers"); once the kit
exists, the Postgres backend implements a descriptor and consumes the kit
instead of extending `BackendParityTest` in place. The kit gates that plan's
acceptance.

## Motivation

Any storage backend outside this repo — community adapters, downstream
platform packages — needs the framework's behavioral contract as a consumable
artifact, not as tests buried in another package's `tests/` directory. And the
in-repo state has real gaps worth fixing regardless:

- **Backend parity is asserted only between in-memory and SQLite** — the three
  suites in `reventless-local/tests/adapter/` (`BackendParityTest`,
  `QueryDbListPushdownParityTest`, `EventLogSnapshotParityTest`). DynamoDB is
  covered by a *separate* integration suite
  (`reventless-aws/tests/integration/`, DynamoDB-Local harness) that shares no
  scenarios with the parity suites. There is no single behavioral contract all
  backends demonstrably satisfy.
- The DCB append-condition semantics — the framework's hardest correctness
  surface (see `docs/analysis/dcb-dynamodb-consistency-check.md`) — have no
  backend-neutral scenario suite at all; each backend's tests grew
  independently.
- The AWS integration lane runs `continue-on-error: true` in CI, so even the
  DynamoDB-specific behavioral checks don't gate.
- Packaging accident: `@reventlessdev/reventless-local` has no `files` field
  and its `.npmignore` excludes only build artifacts — **the published tarball
  ships the whole `tests/` tree**, including the parity suites. Tests-only
  code should not ship; the contract that *should* be consumable should be a
  real package.

Non-motivation to be explicit about: this is not about testing full platforms
end-to-end. Nothing in the repo boots a live `Platform` inside a test today
(the GWT PPX suites are pure in-memory expansions; `reventless-gwt`'s
`LocalHost` reads `pluginStructure` cold). The kit starts at the layer where
parameterization already works: adapter operations.

---

## Design

### Parameterization unit: backend descriptor

The `EventLogSnapshotParityTest` shape (an array of named `makeOps` factories)
is the template — not `BackendParityTest`'s `BackendState` global toggle,
which is a `reventless-local` implementation detail no third-party backend
can satisfy. The kit exports a descriptor record, roughly:

```rescript
type capability = ConcurrentWriters | Ttl | ListPushdown | StrongConsistency | ...
type descriptor = {
  name: string,
  makeEventLogOps: option<lifecycle => promise<EventLog_Adapter.operations<_>>>,
  makeDcbOps: option<lifecycle => promise<DcbEventLog_Adapter.operations>>,
  makeQueryDbOps: option<lifecycle => promise<...>>,
  makeQueryEngine: option<...>,
  capabilities: array<capability>,
  // lifecycle: per-scenario setup/teardown (fresh store or reset)
}
```

Suites are plain Jest-registering functions (`Suite.register(descriptor)`) so
consumers run them inside their own Jest/CI setup with whatever
infrastructure (nothing, containers, emulators) their backend needs. Optional
sections (`option<...>` makers) let a backend certify only the seams it
implements; capability flags gate scenarios that not every backend can honor
(e.g. `ConcurrentWriters` — SQLite's single-writer model can't meaningfully
run race scenarios; TTL filtering is a QueryDb option not all stores expose).
**Skips must be loud**: the runner reports "N scenarios skipped by
capability", never silently green.

### Suite inventory (v1)

1. **Classic event log contract**: append/replay round-trip, OCC conflict
   (`Conflict` typing), `replayStream ~fromSeq` ≡ tail of full replay,
   snapshot round-trip + keep-one + per-aggregate isolation — ported from
   `BackendParityTest` + `EventLogSnapshotParityTest`.
2. **DCB event log contract** (new, the kit's main value): append-condition
   semantics scenario-by-scenario against the dcb.events model — create guard
   (`after` omitted), `after`-cursor conflicts, OR-across-query-items,
   AND-within-item (types × tags), tag containment, cursor
   opacity/monotonicity (returned head positions are stable and ordered),
   `read ~after` exactness, unconditional append, **empty tag values** (an
   absent composite-partition member appends, is recorded verbatim, and stays
   matchable through its partition and composite reads — the divergence in
   `docs/plans/done/dcb-empty-tag-values-break-append.md`, currently asserted
   three times in three places). Sources: the behaviors the DynamoDB and SQLite
   implementations already assert separately, unified.
3. **QueryDb storage contract**: save/loadStream, counters, TTL
   (capability-gated) — from `BackendParityTest`.
4. **Query engine contract**: the `QueryDbListQuery.run` spec-equivalence
   matrix from `QueryDbListPushdownParityTest`, generalized: "your push-down,
   where you claim one, must equal the shared spec over a full scan; declined
   shapes must fall back."
5. **Concurrency suite** (capability `ConcurrentWriters`): two-writer
   write-skew on overlapping condition queries, N-writer single-boundary
   storm (all succeed or conflict cleanly, no lost updates),
   reader-visibility under out-of-order commit (a late-committing earlier
   position must not be skipped past a checkpoint). Drives with genuinely
   parallel connections where the descriptor provides them.

### What the existing suites become

The three `reventless-local/tests/adapter/` parity suites are ported into the
kit and their in-repo files reduce to thin descriptor definitions + kit
invocation (memory descriptor, SQLite descriptor). `reventless-aws` adds a
DynamoDB-Local descriptor to its integration lane — for the first time
running the *same* scenarios as the local backends. Backend-specific tests
(e.g. DynamoDB transaction-assembly internals, SQLite dialect details) stay
where they are; the kit owns only backend-neutral behavior.

### Runtime backend obligation: Monitoring seam

Beyond the storage contracts above, a **runtime** backend (an implementation of
`ReventlessCore.Runtime.environmentMaker`) carries one additional conformance
rule from the deploy-time Monitoring seam (`docs/plans/monitoring-hook-seam.md`):

- **Every execution unit a backend provisions MUST be announced exactly once via
  `ReventlessCore.Monitoring.notify`**, with the `unitKind` role it plays, the
  unit's static logical `~name`, and its `Adapter.resource`. A backend that also
  provisions a dead-letter mechanism announces it with `DeadLetterSink`. Backends
  that provision no compute unit (in-memory/local) call nothing.

This is a static/structural rule, not a Jest suite: it is enforced at the
provisioning choke point (`makeFromCodeAsset` gains a required `~unitKind`
argument, so the compiler proves the sweep is exhaustive) rather than by a
scenario. A behavioral check — register a recording backend in an example deploy
and assert one `notify` per provisioned unit plus one `DeadLetterSink`, with
`component.name` resolving to the unit's native name — belongs to the platform
conformance track (C2), if that harness is ever built.

---

## Phasing

| Phase | Item | Package | Class |
|---|---|---|---|
| A1 | Package scaffold, descriptor + capability types, Jest-registration pattern | reventless-conformance | Plumbing |
| A2 | Port classic event log + QueryDb + query engine suites (inventory 1, 3, 4) | reventless-conformance | Feature |
| A3 | `reventless-local` consumes kit (memory + SQLite descriptors); old parity files reduced to descriptors | reventless-local | Integration |
| A4 | DCB contract suite (inventory 2) | reventless-conformance | Feature (main value) |
| A5 | Concurrency suite, capability-gated (inventory 5) | reventless-conformance | Feature |
| B1 | DynamoDB-Local descriptor in the aws integration lane | reventless-aws | Integration |
| B2 | CI: kit lanes gate for local; decide gating posture for the DynamoDB-Local lane (currently continue-on-error) | repo CI | Hardening |
| B3 | `files` field for `reventless-local` (stop shipping `tests/`); audit siblings for the same gap | reventless-local | Hygiene |
| C1 | Channel/transport contract suites (CommandTopic/EventCollector delivery, retry, ordering semantics) | reventless-conformance | Later |
| C2 | Platform-level behavioral conformance (live `deployPlugin` loop) | — | Explicitly deferred |

Order: A1→A2→A3 lockstep (porting proves the descriptor design), then A4/A5;
B-items any time after A3. C1 when a second transport implementation exists
to test against; C2 has no in-repo precedent (no live-platform test harness
exists) and needs its own design if ever pursued.

## Non-goals (v1)

- Platform-level (deploy/boot) conformance — see C2.
- Performance benchmarks or throughput claims — behavioral contract only.
- A custom runner/CLI — Jest registration functions suffice; formatters and
  orchestration remain the consumer's concern.
- Adopting the dcb.events shared test vectors — track their convergence;
  fold them into suite 2 when stable (a credible public conformance artifact
  for any backend that passes).

## Risks / open questions

- **Descriptor API stability**: third-party backends couple to it; keep the
  record `@live`-documented and additive-only after first publish (new
  optional makers + capabilities, never reshaped requireds).
- **Concurrency scenarios in Jest**: parallel writers via multiple
  connections in one process are sufficient for lock-queueing and write-skew
  scenarios, but timing-based assertions must be avoided (assert outcomes,
  not interleavings) or the suite will flake exactly where it matters most.
- **Scenario drift**: once suites live in a published package, in-repo
  backends must not grow behavior the kit doesn't capture — new adapter
  behavior lands with a kit scenario in the same change (review rule, note in
  CONTRIBUTING).
- **Version coupling**: the kit versions against the adapter interface
  modules (`EventLog_Adapter`, `DcbEventLog_Adapter`); a backend certifies
  against a (kit version, core version) pair. Document the pairing; the
  lerna train keeps them aligned in-repo.
