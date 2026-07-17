# Analysis: DCB high-contention handling

**Status**: Analysis (2026-06-21). Companion to [dcb-consistency-check-issues.md](dcb-consistency-check-issues.md) and the [dcb-consistency-hardening](../plans/dcb-consistency-hardening.md) roadmap (Phase 5a opt-in strong reads, Phase 6 / Issue 10 hot-tag contention).
**Purpose**: treat *high contention* as a first-class concern rather than a side-effect of one knob. Enumerate the contention regimes a DCB slice can hit, the knobs available to relieve each, the sync→async lever specifically, and the control surfaces that could apply these knobs — including automatically. Grounds the decision to keep Phase 5a's strong-read flag build-time-only for now, and the decision *not* to close a naive auto-tuning loop.

---

## 1. Where contention actually bites

One consistency-checked command (`StateChangeSlice_Callback.handleSingleCommand`) costs:

1. **Decision-model read** — for each query clause, a DynamoDB read (single-tag → base-table partition query; multi-tag → `tag_composite` GSI; tagless → scan). The fold consumes the whole matching stream (delta-bounded since the Phase 4 cache, else full history).
2. **Transactional append** — one `TransactWriteItems` = event Puts + fence Updates/ConditionChecks. Each item is billed at 2× (transactional) and the condition is evaluated **strongly** at commit.
3. **On conflict, retry the whole cycle** — up to `maxRetries = 3` ([`StateChangeSlice_Callback.res:96`](../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L96), loop at [:309-331](../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L309)).

**The two populations of append-conflict** (this distinction governs which knob helps):

- **(P1) Replica-lag staleness** — the read missed an *already-committed* write because an eventually-consistent read hit a lagging replica. The append's fence condition (evaluated strongly) rejects it. **Strong reads eliminate P1.**
- **(P2) Genuine concurrent writers** — N writers on the same fence value each read the latest, each decide, the fence serializes them at append, so N−1 lose and retry. **Strong reads do *not* help P2** — the conflict is at the append fence, not the read.

Under real hot-tag load, **P2 dominates**. This single fact is why strong-reads-on-contention is the wrong reflex and why most of the high-leverage knobs below target P2, not P1.

---

## 2. Taxonomy of high-contention regimes

| # | Regime | Root cause | Population | How it surfaces today |
|---|---|---|---|---|
| **R-A** | **Hot partition fence** — one tag value, many concurrent writers | A single `fence#<key>:<value>` item caps at ~500 conditional tx/s (DynamoDB ~1000 WCU/partition ÷ 2 WCU/transactional item) | P2 | retry `WARN`s climb; bursts → `Conflict` rejections (Issue 10) |
| **R-B** | **Hot composite fence** — many writers on the same multi-tag boundary | Same as R-A but on `tag_composite` | P2 | as R-A |
| **R-C** | **Same-entity command burst** — many commands for one entity id arrive together | On the *sync* path nothing serialises them; they read concurrently and race the fence (and the `after=None` create-race, Issue 2) | P2 (+ create-race) | retry `WARN`s; pre-Phase-2 also duplicate creates |
| **R-D** | **Cross-entity fan-out** — one command touching many tag values (e.g. order with 90 products) | Each distinct tag adds a fence item; 100-item `TransactWriteItems` cap is a hard cliff (Issue 11) | write-amplification | `AppendFailed` on >100 items; high WCU/command |
| **R-E** | **High-cardinality read** — a slice reads a tag value that has accumulated huge history | Unbounded decision read O(events matching query); strong-consistent doubles RCU | read cost (not a conflict) | latency + RCU growth; mitigated by Phase 4 cache / Limit:N+1 |
| **R-F** | **Replica-lag window** — eventual reads under moderate concurrency | The P1 staleness window itself | P1 | extra retries that *succeed* on re-read |
| **R-G** | **Lambda / downstream throttling** — command-handler Lambda concurrency or DynamoDB capacity exhausted | Reserved concurrency too low; on-demand ramp; provisioned WCU exceeded | infra | SQS redrive/age, Lambda throttles, `ProvisionedThroughputExceeded` |

The roadmap already owns some of these: R-C create-race = Issue 2 (**done**); R-D cliff = Issue 11 (documented); R-A/R-B = Issue 10 (Backlog); R-E = Phase 4 cache + Phase 7 `Limit:N+1`. This doc is about the *response surface* across all of them.

---

## 3. The knobs

| Knob | Targets | What it does | Cost / blast radius |
|---|---|---|---|
| **K1 Read consistency** (strong / eventual / *escalate-on-retry*) | R-F (P1) | Eventual halves decision-read RCU; strong removes P1 conflicts only | Strong = 2× RCU on every read; does nothing for P2 |
| **K2 Retry policy** (count, backoff, jitter) | R-A,B,C,F (P2+P1) | More retries + exponential backoff + jitter spread contending writers in time → fewer simultaneous fence hits | Latency under contention; today: 3 retries, **no backoff, no jitter** (immediate re-attempt) |
| **K3 Sync → async command handling** | R-A,B,C (P2) | FIFO `messageGroupId = entityId` *serialises same-entity commands* → eliminates same-entity races entirely (no conflict, no retry) | Caller gets `CommandPending` (must poll `Subscription.onX`); +SQS latency; per-group throughput bound. §4 |
| **K4 Fence sharding** (Issue 10 §1) | R-A,B (P2) | Spread one hot fence value across N shard rows; reader checks all N, writer bumps one | N× fence WCU; reader fan-out; profile-gated |
| **K5 Selective fence bumping** (Issue 10 §2) | R-A,B (P2) | Don't bump fences a command doesn't constrain → fewer writers contend on each fence | Pure win where applicable; needs per-clause fence scoping |
| **K6 Decision-model cache** (Phase 4, done) | R-E, shrinks P1/P2 window | Delta read instead of full history → smaller read → shorter read→append window → fewer conflicts | In-process, per warm container; already shipped |
| **K7 Count-bounded read** (`Limit:N+1`) | R-E | For capacity invariants ("≤ N"), read only N+1, not all | Only valid for count/threshold decisions |
| **K8 Capacity mode** | R-G | Provisioned + auto-scaling, or on-demand, or DynamoDB adaptive capacity for hot partitions | Cost vs headroom tradeoff; infra-level |
| **K9 Command coalescing** | R-A,C | Merge many same-entity commands into one (debounce) before the handler | Semantics change; only for idempotent/accumulating commands |
| **K10 Event partition-key sharding** | R-A | Write-shard the event partition itself (suffix), scatter-gather on read | Heavy; read complexity; usually K4 is enough |

**Observation**: only **K1** touches read consistency. The contention-relevant knobs are mostly **K2, K3, K4, K5** — and of those, **K2 (backoff+jitter)** and **K3 (async)** are the cheapest, highest-leverage, and currently *unexploited* for this purpose.

---

## 4. Deep dive — sync → async as a contention remedy (K3)

The single most effective lever for **same-entity contention (R-C, and R-A when the hot tag is the entity's own partition)**.

**Mechanism.** `@@reventless.async` on a StateChangeSlice routes its commands through `CommandTopicChannel_SQS_Async`, a **FIFO** queue whose `messageGroupId = safeGroupId(commandJson.id)` ([`Util_SQS_Runtime.res:43`](../../reventless/aws/src/util/Util_SQS_Runtime.res#L43)); for DCB slice commands `commandJson.id` **is the entity/partition id** ([`StateChangeSlice_Callback.res:108`](../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L108)). FIFO guarantees **at most one in-flight message per group**, so same-entity commands are processed **strictly one at a time**.

**What it fixes.** For a single entity there is now never a concurrent reader/writer pair → **P2 same-entity conflicts vanish, and so do their retries** (and the Issue 2 create-race — already noted in Phase 2A as closed for async slices). Different entities still run fully in parallel (different `messageGroupId`s), so throughput across the keyspace is unaffected.

**What it does *not* fix.** Contention on a tag that is *not* the command's entity id — e.g. many *different* orders all fencing on the same `productId` (R-A with a *shared secondary* hot tag). Those commands have different `messageGroupId`s, so FIFO doesn't serialise them. That residue is K4/K5 (sharding / selective bumping) territory.

**Costs / tradeoffs.**
- **Caller contract changes**: async returns `CommandPending` (fire-and-forget), not inline `CommandAccepted`/`CommandRejected`. Callers must observe the outcome via `Subscription.onX`. This is a real API/UX shift, not transparent.
- **Latency**: +SQS hop; serialisation means a hot entity's commands queue behind each other (bounded throughput per entity — which is exactly the point, but it is a per-entity ceiling).
- **Lambda topology**: async slices land in a separate `<Plugin>StateChangesAsync` Lambda (per CLAUDE.md), tunable independently via `commandHandlerConfig`.

**When async wins vs. the alternatives.** If contention is **same-entity write bursts** → async is the cleanest fix (turns a race into a queue; zero wasted retries). If contention is **many entities sharing one hot tag** → async does little; reach for **K4/K5** (sharding/selective bumping) or **K2** (backoff to spread them). If the conflict is **pure replica lag (P1)** → async is overkill; **K1/escalate-on-retry** suffices.

**Note on direction**: async *trades retries for queueing latency*. Under heavy same-entity load, sync = many wasted reads+appends (4× work on 3 retries) surfacing as `Conflict`; async = bounded-latency serial processing with **no wasted work**. For high-contention same-entity slices, async is usually the better economic and correctness story — at the cost of the polling contract.

---

## 5. Deep dive — escalate-on-retry consistency (the smarter K1 default)

A refinement that **dominates plain eventual** and resolves most of the "should we auto-tune?" tension locally, with no global state and no metric:

> **First attempt: eventual read (cheap). On any retry: strong read.**

**Why it's strictly better than plain eventual.**
- Happy path (the overwhelming majority — uncontended entities) is **identical to eventual**: one eventual read, append succeeds, full RCU saving. No regression.
- A **P1 (lag) conflict** is fixed deterministically on the *first* retry: the strong re-read is guaranteed to see the latest commit, so the retry can't fail for the same stale-read reason. Plain eventual might burn 2–3 retries waiting for the replica to catch up; escalate-on-retry needs **one**.
- A **P2 (genuine) conflict** behaves the same as today: you were going to retry anyway; the strong read on the retry costs 2× RCU **only on the retry path** (rare, bounded by `maxRetries`), and at least removes any lag component from the re-decision.

**Why it sidesteps the auto-tuning trap.** The escalation is **per-invocation and local** — it reacts to *this command's own* conflict, not a noisy global rate, so it can't misfire the way a "global conflict rate ↑ → everything goes strong" loop does. It spends strong-read RCU exactly where a conflict already proved a re-read is needed, and nowhere else.

**Recommendation**: make `EventualThenStrongOnRetry` the **default** consistency mode, with `Eventual` (never strong) and `Strong` (always) as the explicit per-slice overrides. This captures the cost win *and* the lag-self-heal in one default, and makes plain "eventual everywhere" an opt-in for cost-extremists. (This is a small change to where `~strongConsistency` is computed in the callback retry loop — the retry branch already exists at [:309](../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L309).)

---

## 6. Control surfaces — and which permit *automatic* adjustment

The user's question: when the contention metric goes up, can we adjust at runtime, even automatically? Surfaces, weakest→strongest on the "no redeploy / automatic" axis:

| Surface | Change latency | Automatic? | Notes |
|---|---|---|---|
| **S1 Build-time** (PPX attr / Spec field) | redeploy (CI) | no | Simplest; what Phase 5a ships *now*. Fine for stable, known-hot slices. |
| **S2 Runtime config — Lambda env var** | seconds (`UpdateFunctionConfiguration`) → cold start | manual, or via a controller | No code rebuild; rolls a Lambda config version. |
| **S3 Runtime config — SSM Parameter / AppConfig (TTL-cached read)** | seconds, **no redeploy, no cold start** | manual, or via a controller | Idiomatic here (framework keeps layer ARN in SSM). Adds a cached read in the hot path + per-slice param provisioning. |
| **S4 In-process adaptive** (per warm container) | per-invocation | **yes, fully local** | **Escalate-on-retry (§5) is the safe instance of this.** A rolling-window "conflict rate ↑ → go strong" is the *unsafe* instance (see below). |
| **S5 Control-plane adaptive** (CloudWatch alarm → Lambda/Step Functions controller → writes SSM/env) | seconds–minutes | **yes, closed-loop** | Most powerful; most moving parts. Can pick *different* remedies per signal (lag→strong, contention→shard/async-migration ticket). |

**The signal-ambiguity problem (why naive S4/S5 auto-tuning is a non-goal).** The obvious automatic rule — "append-conflict rate exceeds threshold → switch that slice to strong reads" — is unsound, because conflicts are **mostly P2** (genuine contention), and **strong reads don't fix P2**. The loop would double RCU under load while the conflict rate barely moves, then potentially oscillate. To auto-tune *correctly* you must first **classify the conflict** (lag vs contention), which the raw conflict count doesn't tell you. Distinguishing them needs either:
- a **lag probe** (compare an eventual read vs a strong read on the same key and measure divergence) — extra reads, only sampled; or
- inference from **co-signals** (e.g. high conflict + low concurrency on the key ⇒ likely lag ⇒ strong helps; high conflict + high concurrency ⇒ contention ⇒ strong won't help, route to async/sharding).

**Two safe automatic behaviours we *can* adopt** without solving classification:
1. **Escalate-on-retry (§5)** — local, self-targeting, no metric. Recommended as default.
2. **Backoff + jitter on retry (K2)** — local, helps *P2* directly by de-synchronising contenders; complements escalate-on-retry. Recommended next.

Everything beyond that (S5 closed-loop) should **alarm a human** (or a classification-aware policy) who picks the *correct* remedy — strong (lag), async migration (same-entity contention), or sharding/selective-bump (shared-tag contention). The remedy menu is regime-specific (§2/§3); a one-dimensional auto-flip can't represent it.

---

## 7. Provider-genericity — what's portable vs. what each backend must implement

The contention machinery follows the repo's **Adapter pattern**: a provider-agnostic *policy + interface* in core/infra, and per-provider *implementations* that honor each knob to the extent their engine allows. Critically, the knobs are **not** uniform in how portable they are — some degrade safely to no-ops on backends that don't support them, others are hard requirements without which the whole consistency model breaks.

**The layering (where each piece lives, and the provider story):**

| Concern | Where it lives | Provider story |
|---|---|---|
| Escalate-on-retry policy (§5) | core callback (`StateChangeSlice_Callback`) | **fully generic** — one implementation, backend-blind |
| Retry count + (future) backoff/jitter (K2) | core callback | **fully generic** |
| `~strongConsistency` read hint (K1) | infra/core interface (`DcbEventLog.readStream`) | generic interface, **best-effort** per backend — a *hint*, not a guarantee |
| Append fence / OCC (the load-bearing part) | storage adapter (`*_Runtime`) | **hard requirement** — each backend must provide an atomic conditional append |
| Sync→async serialization (K3) | AWS = SQS FIFO (`messageGroupId`) | concept generic; each provider needs its own ordered-queue primitive |
| Fence sharding / selective bump (K4/K5) | storage adapter transaction building | generic policy, per-backend realization |

**`~strongConsistency` is a capability hint, not a guarantee.** The core callback sets it (eventual-first, strong-on-retry) and passes it down the abstract interface, knowing nothing about the backend. Each adapter honors it as far as it can:
- **AWS / DynamoDB** maps `true` → `consistentRead: true` on single-tag base-table reads. GSI-backed branches (composite, scan) **cannot** honor it — a fundamental DynamoDB constraint — so they ignore it and stay eventual.
- **Local (in-memory / SQLite)** is always consistent, so it accepts the flag for interface parity and ignores it.
- A future provider supplies its own `DcbEventLog.Storage` and decides the mapping.

This best-effort treatment is **only safe because correctness does not depend on the read hint** — it rests entirely on the append fence (a stale read can only cause a rejected append, never a wrong write; §1). So a knob that's purely a *cost/latency* optimization (read consistency) can degrade to a no-op anywhere, while the *correctness* primitive (the fence) cannot.

**The hard provider requirement: atomic conditional append.** The OCC model assumes the backend can append events and check/advance fence rows in **one atomic conditional transaction** (DynamoDB: `TransactWriteItems` with condition expressions). A backend without atomic conditional writes cannot implement DCB consistency at all — no amount of read-consistency tuning rescues it. This is why the local backends "don't use fences": single-process, they serialize naturally and need no fence machinery to be correct. Any new cloud provider (GCP, Azure, …) must supply this primitive in its `Storage` adapter; the core policy then composes on top unchanged.

**Today's breadth (honest scope):** the structure is provider-generic, but only **two** backends exist — **AWS** (`reventless-aws`, the only real cloud implementation) and **local** (`reventless-local`: in-memory + SQLite). "Applies to all providers" is a design contract, not shipped breadth. Adding a provider means implementing its `DcbEventLog.Storage` (atomic conditional append + a read-consistency mapping + an ordered-queue primitive for K3); the generic core knobs (K1 hint, K2 retry/backoff, escalate-on-retry, cache) then work without change.

## 8. Recommendations & sequencing

**Now (Phase 5a, this work):**
- Default decision-read consistency = **eventual**; **per-slice build-time flag** to force strong (S1). *(Decided.)*
- **Strongly consider making the default `EventualThenStrongOnRetry` (§5)** rather than plain eventual — same happy-path saving, deterministic lag-self-heal, no auto-tuning risk. **Open question for the owner.**
- Ship the **per-slice retry/conflict metric**, split by the layering (§7): core emits a **provider-neutral** structured metric line (no `_aws`/EMF — that vocabulary must not live in core); `reventless-aws` turns it into a CloudWatch metric via a deploy-time `LogMetricFilter` on the command-handler log groups. Makes the eventual default observable and is the input to any future controller.

**Next (cheap, high-value, not yet exploited):**
- **K2 backoff + jitter** in the retry loop — directly attacks P2 by spreading contenders; today the loop retries immediately. Small, local, no contract change.

**Profile-gated (Phase 6 / Issue 10 + this doc):**
- **K3 async migration** for slices whose contention is **same-entity** — the cleanest fix (turns race into queue), at the cost of the `CommandPending` contract.
- **K4/K5 sharding + selective bumping** for slices whose contention is a **shared hot tag** across entities.
- **S3 SSM runtime override** + **S5 alarm-driven controller** once metrics show a real, recurring hot slice — and only with conflict *classification*, never a raw-rate auto-flip.

**Non-goals (documented, deliberate):**
- Naive closed-loop "conflict rate ↑ → strong reads" — wrong remedy for the dominant (P2) conflict population; would burn RCU without relieving contention.

**One-line decision aid** — *what is the conflict?*
- pure replica lag → **K1 escalate-on-retry / strong**
- same-entity bursts → **K3 async** (+ K2 backoff)
- shared hot tag across entities → **K4/K5 sharding / selective bump** (+ K2 backoff)
- huge per-key history → **K6 cache / K7 Limit:N+1**
- infra ceiling → **K8 capacity / concurrency**
