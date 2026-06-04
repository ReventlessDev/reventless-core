# Fix the inert plugin-retire hook (FIFO-only params on a standard queue)

Scope: make `publishRetireForOlderPluginVersions` actually deliver its
`Retire` command. This is the fix for the **two-connected-versions**
duplication observed on `online-shop-hybrid` — it closes the ~7-minute
deploy-overlap window. Single-function change in `reventless-aws`, plus
hardening so this class of failure can't stay silent again.

Companion to [plugin-retired-state-version-supersession.md](plugin-retired-state-version-supersession.md)
(the state-machine correctness change). This plan is what removes the
duplicate-version symptom; that plan makes the retirement destination
state semantically correct. They compound; neither alone is sufficient
for the ideal end state, but **this one alone removes the symptom.**

## Sequencing — ship this FIRST

These are deliberately **two separate plans**, not one:

1. **This plan first.** Small, low-risk, `fix(aws):` patch in
   `reventless-aws` only; stops a live user-visible problem (two
   connected versions on the site). No schema or behavior change.
2. **Then** [plugin-retired-state-version-supersession.md](plugin-retired-state-version-supersession.md) —
   larger `feat(admin)!:` change to the core Plugin aggregate / read
   model / projection / tests.

Rationale: disjoint packages and files (no merge friction), distinct
conventional-commit types (Lerna versioning), and one real directional
dependency — the Retired-state change can only be **fully verified on a
live stack once retire actually fires**, i.e. after this fix. Shipping
this alone lands superseded versions in today's `Inactive` state (the
pre-existing conflation), which is acceptable as an interim until the
companion plan upgrades the destination to `Retired`.

## Root cause (proven)

### Live evidence

Plugin read model (`Plugins-d4612ef`, alpha/eu-west-1) shows every old
version timing out via the heartbeat Scheduler, never retired:

```
Disconnected  Catalog@1.0.0-alpha.67   by: Scheduler
Connected     Catalog@1.0.0-alpha.71   by: Heartbeat
```

The successful June-4 deploy (GH Actions run `26960770876`,
`Deploy Online Shop Hybrid`) shows the hook firing and then failing:

```
[publishRetireForOlderPluginVersions] retiring Catalog@1.0.0-alpha.67 (superseded by Catalog@1.0.0-alpha.71)
[publishRetireForOlderPluginVersions] skipped for Catalog@1.0.0-alpha.71
   (Value <uuid> for parameter MessageDeduplicationId is invalid.
    Reason: The request include parameter that is not valid for this queue type.)
```

(Identical for Ordering.) So: the gate passed, the RM scan found the
stale version, and the publish was attempted — only the `SendMessage`
call failed.

### Why it fails

`MessageDeduplicationId` and `MessageGroupId` are **FIFO-only** SQS
parameters. The Plugin aggregate's command-topic queue is a **standard**
queue — confirmed live: `PluginAggrCmdTopic-8c970d1` has no `.fifo`
suffix (and so do all command-topic queues on this stack —
`CategoryAggrCmdTopic`, `CustomerAggrCmdTopic`, `CatalogStateChangesCmdTopic`,
…; only the `FIFODeadLetterQueue-*.fifo` queues are FIFO).

The retire hook hand-rolls the `SendMessage` envelope
([Platform.res:630-637](../../reventless/reventless-aws/src/Platform.res#L630-L637))
because the deploy-time hook can't reach the runtime `Util_SQS_Runtime`
Effect pipeline (comment at [:612-615](../../reventless/reventless-aws/src/Platform.res#L612-L615)).
It **unconditionally** sets both FIFO params:

```rescript
AwsSdk.SQS.SendMessageCommand.make({
  AwsSdk.SQS.SendMessageCommand.queueUrl: cmdTopicUrl,
  messageBody,
  messageGroupId: Util_SQS_Runtime.safeGroupId(id),     // FIFO-only
  messageDeduplicationId: msgId,                          // FIFO-only
})
```

SQS rejects the call for a standard queue, the surrounding best-effort
`try/catch` ([:639-645](../../reventless/reventless-aws/src/Platform.res#L639-L645))
logs `skipped …` and swallows it, the deploy proceeds, and the `Retire`
never reaches the Plugin aggregate. The old version then stays `Connected`
until its disconnect schedule fires (~heartbeat interval + 2 min) → the
~7-minute overlap during which both versions are `Connected` and the
manifest returns both.

## Fix

### 1. Conditional FIFO params keyed on queue type

[reventless/reventless-aws/src/Platform.res:612-637](../../reventless/reventless-aws/src/Platform.res#L612-L637)

Only attach `messageGroupId` / `messageDeduplicationId` when the target
queue is FIFO (URL/name ends in `.fifo`):

```rescript
let isFifo = cmdTopicUrl->String.endsWith(".fifo")
let sendInput: AwsSdk.SQS.SendMessageCommand.input = isFifo
  ? {
      queueUrl: cmdTopicUrl,
      messageBody,
      messageGroupId: Util_SQS_Runtime.safeGroupId(id),
      messageDeduplicationId: msgId,
    }
  : {
      queueUrl: cmdTopicUrl,
      messageBody,
    }
let _ = await AwsSdk.SQS.SendMessageCommand.send(
  AwsSdk.SQS.SendMessageCommand.make(sendInput),
)
```

(`messageGroupId` / `messageDeduplicationId` are optional record fields,
so the standard-queue branch simply omits them.) Dropping them on a
standard queue is safe: `Retire` is idempotent
([PluginBehavior.res:113](../../reventless/reventless-core/src/admin/PluginBehavior.res#L113))
so at-least-once / unordered delivery is fine, and there is exactly one
`Retire` per superseded row per deploy.

Verify the exact field names of `AwsSdk.SQS.SendMessageCommand.input`
in the bindings before finalizing the record literal.

### 2. Make this failure class non-silent

The hook is intentionally best-effort so it never blocks a deploy — keep
that — but a `SendMessage` rejection is a real bug, not an expected skip.
Differentiate in the `catch` ([:639-645](../../reventless/reventless-aws/src/Platform.res#L639-L645)):
log at a clearly-elevated level (e.g. prefix `ERROR` / `⚠️`) and include
the queue URL and whether it was detected as FIFO, so a future regression
surfaces in the deploy log instead of hiding behind `skipped …`. Consider
emitting a distinct marker string that a deploy-smoke assertion can grep.

### 3. (Optional, larger) Route through the canonical publish helper

The hand-rolled envelope exists only because the Effect pipeline isn't
reachable at deploy time. If a thin, dependency-free SQS publish helper
that already does FIFO detection can be shared between
`Util_SQS_Runtime` and this hook, prefer that over duplicating the
`.fifo` check — it removes the root assumption (FIFO-always) rather than
patching it. Out of scope for the minimal fix; note for follow-up.

## Verification

1. `pnpm exec rescript build` clean (zero warnings).
2. Redeploy `online-shop-hybrid` on alpha. In the `Deploy Plugin (catalog)`
   / `(ordering)` logs, confirm the line is now `retiring …` **without** a
   following `skipped …` (or with an explicit success marker).
3. Scan `Plugins-d4612ef`: the prior version's row should be
   `Inactive` (current model) / `Retired` (if the companion plan landed),
   with `statusChange.by = "deploy:<name>@<version>"` rather than
   `"Scheduler"`. The only `Connected` rows should be the just-deployed
   version.
4. Run the production manifest filter
   (`contains(status, "Connected")`) against the table — exactly one row
   per plugin.
5. Hit the live site immediately after deploy — a single version of each
   plugin, with no ~7-minute dual-version window.

## Notes / open questions

- **Why are command topics standard, not FIFO?** `CLAUDE.md` and the
  architecture docs describe CommandTopic → SQS **FIFO**, but every
  command-topic queue on this stack is standard. Either the convention
  changed, FIFO is opt-in/config-gated, or the docs are stale. Worth a
  quick reconciliation — but the retire fix must handle standard queues
  regardless, because that is what is deployed. If command topics are
  *meant* to be FIFO, there is a separate infra bug (the queues aren't
  FIFO); the `.fifo`-detection fix is correct under either outcome.
- **Backfill the existing stuck rows.** The current `Disconnected`
  alpha.65/66/67 rows won't retroactively become retired. They're
  already filtered out of the manifest, so this is cosmetic; if desired,
  publish a one-off `Retire` (via a correctly-typed send) per stale row,
  or let the next deploy's now-working retire handle the most recent one.
  Note the older ones (65/66) won't be touched by retire since they're
  already not `Connected` — the scan filters on `status = "Connected"`.

## References

- [Platform.res:575-646](../../reventless/reventless-aws/src/Platform.res#L575-L646) — `publishRetireForOlderPluginVersions` (the hand-rolled send at 630-637).
- [Platform.res:1019-1028](../../reventless/reventless-aws/src/Platform.res#L1019-L1028) — call site (gate passes; confirmed live).
- [Platform.res:1697-1708](../../reventless/reventless-aws/src/Platform.res#L1697-L1708) — `pluginAggrCmdTopicUrl` export (the queue URL; confirmed populated).
- GH Actions run `26960770876` — deploy log with `retiring … / skipped …`.
- Live queue `PluginAggrCmdTopic-8c970d1` (eu-west-1) — standard, not FIFO.
- [plugin-retired-state-version-supersession.md](plugin-retired-state-version-supersession.md) — companion correctness plan.
</content>
