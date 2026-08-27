# Plan: the manifest bake's convergence check can fail forever, and cannot say why

**Date:** 2026-08-27
**Status:** PROPOSED — nothing implemented.
**Repos:** `reventless-core` only.
**Relates to:** [baked-manifest-without-host-ui-bundle.md](./baked-manifest-without-host-ui-bundle.md)
(a platform that cannot bake at all — a different gap in the same feature) and
[plugin-definition-schema-evolution-guards.md](./plugin-definition-schema-evolution-guards.md)
(what happens when a persisted definition predates a field).

## What was seen

On a live estate, every stack deployed cleanly and the manifest bake then failed: one plugin of
six never satisfied the convergence check, through 20 attempts, twice — a re-run reproduced it
exactly, so it is a standing mismatch and not a slow projection.

The bake compares the structure key a plugin's stack exported (`pluginStructureRef`,
`aws/src/Platform.res`) against the key on that plugin's Plugin read-model row, and refuses to
write until they agree. Refusing was **correct**: the manifest would otherwise have described the
previous deployment, which nothing downstream could detect. The design is right; two things
around it are not.

## Defect 1 — the check is green for the wrong reason

The comment on `structureOffloadKey` states the property plainly: the equality check "passes
immediately for a plugin whose structure did not change." That is a deliberate and desirable
optimisation — but it means **a plugin whose structure is unchanged passes without exercising
the re-detect → handle → project chain at all.**

So on the run above, five of six plugins passed because they had nothing to update. Only the
sixth — the one whose structure genuinely changed — actually tested the mechanism, and it
failed. A green bake therefore says "nothing needed to converge" far more often than it says
"convergence works", and the difference is invisible in the job's output.

The consequence is the serious part: **this path can be broken for an arbitrary number of green
deploys**, and the first deploy that changes any plugin's structure is where it surfaces —
maximally far from whatever broke it.

## Defect 2 — the failure carries no evidence

When it does fail, the job reports one thing: the plugin's name. It does not report

- the key it expected (it has this — it printed `Expecting:` earlier in the same job),
- the key the read-model row actually holds,
- when that row was last written,
- which link of the chain did not happen.

Three links can each produce this identical symptom: the re-detect was never published, the
plugin never answered it, or the projection never landed. A fourth is worse — that the plugin
*did* answer and produced a **different structure than the deploy hashed**, in which case the two
keys can never converge and every retry is spent waiting for something that cannot happen.

Diagnosing which required reading the read model directly, out of band, with credentials the
deploy pipeline does not surface. That is the gap this plan exists to close: the bake already
knows both halves of the comparison and reports neither.

## The invariant nobody checks

Content addressing makes the key a *consequence* of the structure bytes, so convergence requires
that **the structure the deploy hashes and the structure the plugin's own registration produces
are byte-identical.**

Those are produced by two independently built artifacts: the deploy program, resolved from the
deploying workspace's install, and the plugin's runtime, whose framework comes from the Lambda
layer — resolved from SSM, on its own release cadence. Nothing asserts the two agree. When they
diverge — a layer built against a different framework version, a field emitted on one side and
not the other, a filter applied in one path — the only signal is a hash that silently never
matches, which is exactly the shape of the failure above.

This is also why a version bump is a plausible trigger even when every stack deploys cleanly:
adding a field to a definition changes the bytes on whichever side is rebuilt first.

## Phases

### §1 — Make the failure state its evidence (do first; everything else is easier after)

The bake handler compares two keys per plugin. Have it return both, plus the row's last-written
timestamp, and have the workflow print them on each pending attempt. Turning "pending:
`<plugin>`" into "expected `sha256/A`, row holds `sha256/B`, written at `T`" separates the four
causes above on sight, and costs one field in a response that is already being returned.

`A == B` never appearing while `T` keeps advancing is the divergence case; `T` frozen at a
pre-deploy instant is one of the three missing-link cases.

### §2 — Distinguish the links

Given §1, name which step is outstanding rather than reporting the aggregate. The re-detect's
publication, the plugin's answer and the projection's write are three observable events; the
handler can say which it is still waiting on.

### §3 — Remove the divergence, rather than detect it faster

Two candidate designs, to be chosen once §1 says what actually diverges:

- **Carry the key instead of recomputing it.** The deploy has already written the structure
  object and knows its key; if the re-detect carries that key and the plugin's registration
  records what it was told, the two sides cannot disagree by construction. The plugin still
  serves its own structure; it stops independently deriving the *identity* of one.
- **Derive both sides from one artifact.** Stronger and more invasive: the deploy and the runtime
  resolve the structure from the same built module, so no second computation exists.

The first is preferred: it is smaller, and it makes the invariant structural rather than
maintained. Note it also changes what a mismatch *means* — with the key carried, a difference
becomes "the plugin did not register" and never "the plugin registered something else", which is
the ambiguity §1 currently has to resolve by hand.

### §4 — Stop reporting an untested path as a pass

Keep the unchanged-structure fast path — it is what makes the bake cheap — but record it as
`unchanged` rather than folding it into `matched`, and have the job say how many plugins actually
exercised the chain. A deploy where that count is zero has verified nothing about registration,
and should say so rather than printing a green tick.

### §5 — A test that would have caught it

An integration case where a plugin's structure **changes** between two deploys and the bake is
required to converge. The existing coverage cannot catch this class: an unchanged structure
converges trivially, so a test that does not mutate the structure passes against a completely
broken chain.

## Risks and notes

- **Do not "fix" this by widening the retry budget.** The re-run reproduced the failure exactly;
  more attempts would only spend longer reaching the same conclusion, and would make a standing
  divergence look like flakiness.
- **The refusal is the good part.** Whatever changes, the bake must keep declining to write a
  manifest it cannot prove is current — a well-formed manifest of the wrong deployment is the
  failure mode this check exists to prevent, and it is undetectable downstream.
- **`retainOnDelete` on the structure objects is load-bearing** and its reasoning (the read model
  points at the previous object during the async window) is adjacent to this plan: §3's first
  option shortens that window's blast radius but does not remove the need.
