# Plugin names — identity, namespace, and what happens when two plugins claim one

**Status:** Analysis
**Date:** 2026-08-01
**Plans:** [task-bucket-naming-and-declared-store-wipe.md](../plans/task-bucket-naming-and-declared-store-wipe.md) (Part 3 adds the check this analysis argues is necessary but not sufficient)
**Subject:** [`PluginSpec.res`](../../reventless/core/src/plugin/lifecycle/PluginSpec.res), [`Plugin_Structure.res`](../../reventless/core/src/plugin/component/Plugin_Structure.res), [`PlatformCodegen.res`](../../reventless/spec/src/generator/PlatformCodegen.res)
**Question:** Should a platform enforce that no two plugins share a name? Does merging same-named plugins ever make sense? And how does either answer survive installing a plugin whose name the installer did not choose?

---

## Summary

A plugin's name currently does three jobs at once — it is an **identity**, a **namespace**, and a
**reference target**. Nothing enforces uniqueness, and the failure mode is silent: a second plugin
registering an existing name is read as a *new version of the first* and supersedes it.

Enforcing uniqueness is right and should happen, but it is a diagnostic, not a design. It cannot be
the whole answer, because it has no remedy for the case where the installer cannot choose the name.
The remedy is to stop conflating the three jobs: qualify identity so authors cannot collide by
accident, derive rendering from identity per target charset, and resolve references through a
composition-time mapping so authored source never hardcodes an installer's choice.

Deliberately merging two plugins under one identity does **not** make sense and should stay
impossible. The framework already has the sanctioned mechanism for plugins that need each other —
extension points and dotted references — and identity-merging would be a second, worse one that the
version lifecycle cannot express.

---

## 1. What the plugin name is load-bearing for

Verified against the source rather than assumed:

| role | where | consequence of a duplicate |
|---|---|---|
| **Identity** — registry key | [`PluginSpec.res:4-8`](../../reventless/core/src/plugin/lifecycle/PluginSpec.res#L4-L8): "One instance owns the whole lifecycle of every version of that name" | the second plugin reads as a new *version* of the first → `VersionSuperseded` |
| **Capability qualifier** | `{plugin}.{store}` keys from [`Plugin_Structure.res:504-517`](../../reventless/core/src/plugin/component/Plugin_Structure.res#L504-L517), unioned by [`PlatformCodegen.union`](../../reventless/spec/src/generator/PlatformCodegen.res#L40-L61) | two plugins' stores collapse into one entry, indistinguishable from deliberate sharing |
| **Reference target** | `@storageRef("Catalog.productImages")`; dotted extension-point names (`Catalog.Products`) | a reference resolves to whichever plugin won |
| **Schema namespace** | generated GraphQL fields and types | [`GraphQL_Stitcher`](../../reventless/core/src/components/Api/GraphQL_Stitcher.res#L209-L267) *warns and skips* duplicates — the loser's fields silently vanish |
| **Resource namespace** | Lambda / table / queue names, `reventless:plugin` attribution tags | resources are attributed to the wrong plugin |
| **Object-key namespace** | proposed `{plugin}/{store}` prefix (plan Part 4) | two stores share one prefix |

Three distinct jobs are wearing one string:

- **identity** — the thing the registry keys on, that has a lifecycle and versions;
- **namespace** — the prefix rendered into schemas, resource names, tags and object keys;
- **reference** — the token another plugin's *source code* writes down to point at it.

Almost every difficulty below comes from those three having different requirements: identity wants
to be globally unambiguous, namespace wants to be short and charset-legal, and reference wants to be
stable across installations.

## 2. What happens today

Nothing checks uniqueness anywhere. The near-misses are worth naming, because each looks like a
check and is not one:

- **The deploy manifest** lists plugins as a mapping, so its keys are unique — but they are
  *deployable* names, and [`PlatformCodegen.res:76-82`](../../reventless/spec/src/generator/PlatformCodegen.res#L76-L82)
  states that no rule relates a deployable name to a registered plugin name.
- **The Plugin aggregate is keyed by name**, which merges duplicates rather than rejecting them.
- **The capability union** merges by key, which is correct behaviour on the assumption that one key
  means one store.
- **`GraphQL_Stitcher`** detects duplicate *types and fields* and skips them with a warning — the
  only duplicate handling in the composition path, and it is downstream of the actual problem.

The registry outcome is the sharpest: **the version model is working as designed on invalid input.**
Holding every version of a name under one instance, with supersession, is exactly right for the case
it was built for — blue/green rollout of one plugin. It has no way to notice that two artifacts
claiming one name are not two versions of one thing. The defect is the missing precondition, not the
merge logic.

## 3. Should uniqueness be enforced?

**Yes, for identity.** Two distinct plugins under one registry key is incoherent: the row's version
history interleaves two unrelated artifacts, and `VersionSuperseded` fires between things that never
superseded each other. There is no reading under which that is intended.

But enforcement alone has a hole, and it is the one the marketplace question exposes: **a check whose
only remedy is "rename one of them" is not a remedy when the installer cannot rename either.** For
first-party plugins the check is sufficient, because renaming is a source edit. For an installed
plugin it is a wall.

So: enforce, and treat the check as a *diagnostic that must exist* while building the mechanism that
makes it rarely fire. §6 sequences that.

## 4. Does merging make sense?

Two things get called merging; only one of them is real.

**Accidental merge** — what happens today. Never intended, always corruption.

**Deliberate merge** — several deployables jointly owning one plugin identity, so they compose into
one logical plugin. This is the interesting question, and the answer is no, for a reason that is
structural rather than stylistic: **the version lifecycle cannot express it.** A plugin row holds
versions of one artifact and decides supersession between them. Two contributors at independent
versions cannot both be "the current version"; there is no coherent answer to what `Retire` or
`Deactivate` means for half of a plugin, and no way to say which contributor a `VersionConnected`
event describes. Supporting it would mean per-contributor version state — a different aggregate, not
a relaxed constraint.

It is also unnecessary. The framework already has the mechanism for a plugin that needs to reach
another: **extension points and dotted references**. `@storageRef("Catalog.productImages")` shares a
store across a plugin boundary by *reference*, which is the safe form — one owner, many referrers,
one lifecycle. Identity-merging would be a second mechanism for the same goal, with worse
properties. Sharing by reference: yes, already supported. Sharing by identity: no.

## 5. The marketplace case

An installed plugin arrives with a name its author chose. Three different things can then conflict,
and they need three different answers — collapsing them is what makes the problem look intractable.

### 5.1 Identity conflict

Two installed plugins, or an installed one and a first-party one, claim the same registry key.

**Option A — install-time alias.** The platform assigns a local name at composition; the author's
name becomes provenance (publisher, package, version) rather than identity. This is the standard
answer across ecosystems — module aliasing, namespaces, `import X as Y` — and its virtue is that
**the installer, not the author, chooses local identity**, which is precisely the authority the
marketplace case needs. Its cost is §5.3: every source-authored reference has to resolve through the
alias rather than through a literal.

**Option B — publisher-qualified identity.** Identity becomes `{publisher}.{plugin}`, the way scoped
package names and language namespaces work. Collisions then require one publisher to ship two plugins
with one name, which is theirs to prevent. No installer action in the common case. Its cost is that
the qualified form is illegal or unwieldy in most of the namespaces of §1, which forces §5.2.

**Option C — allow duplicates until they actually conflict.** Rejected: the registry damage happens
at registration, which is exactly when "actually conflict" would be evaluated, and the damage is
silent.

**Option D — content-addressed identity** (hash of the plugin definition). Nobody can author a
collision, but nothing is human-referenceable, so §5.3 becomes unsolvable. Useful as *provenance*
alongside a name, not as the name.

**B as the default, A as the escape hatch** covers the space: qualification removes the common
collision with no installer effort, and an alias resolves the residue (two forks of one publisher's
plugin; a legacy unscoped plugin; a deliberate local rename).

### 5.2 Namespace conflict

Identity being unambiguous does not make it *renderable*. A qualified identity has to appear in
GraphQL field names, Lambda and table names, tags, and object-key prefixes — each with a different
legal charset and length budget, and some of them (object prefixes, resource names) permanent once
deployed.

The resolution is to stop rendering identity directly: derive a **rendered name** per target,
sanitised and length-checked, from identity, and never let anyone author the rendered form. That
keeps "two names" from becoming two sources of truth — one is a pure function of the other. The
existing task-bucket naming defect (plan Part 1) is a small instance of the same lesson: a name
composed for one namespace, reused in another with different rules, reads as noise.

### 5.3 Reference conflict

This is the one that makes aliasing non-trivial. References like `@storageRef("Catalog.productImages")`
and dotted extension-point names are written **inside plugin source**, by an author who cannot know
what the installer will call the target. A literal plugin name in source is a hardcoded assumption
about someone else's installation.

So aliasing requires an indirection: source declares a reference by the *author's* name for the
target, and composition resolves it through the installation's mapping. Without that, an alias
silently breaks every cross-plugin reference — which is worse than the collision it fixes.

Two constraints on any such mapping:

- **Stable once deployed.** Under plan Part 4 the plugin segment becomes part of the object key
  prefix, and refs live in an append-only event log, so a *changed* alias breaks existing refs
  exactly as a plugin rename does. An alias is chosen once, at install, and grandfathered
  thereafter — the same shape as the legacy-prefix handling in the plan.
- **Explicit, not inferred.** A mapping guessed from near-matches would eventually resolve a
  reference to a plugin the author never meant, which is the failure the whole exercise is avoiding.

### 5.4 Semantic conflict

Distinct from all of the above, and not solved by any naming scheme: two plugins that both claim to
own the same extension point, or both project into the same read model. Naming makes them
*distinguishable*; it does not decide which one should win. That needs an explicit resolution at
composition, and it is the one area where the answer is genuinely "the operator decides". Out of
scope here, noted so it is not mistaken for a naming problem.

## 6. Recommended sequence

1. **Fail loudly on a duplicate identity.** A deploy-time check over the composed plugin names, and a
   registration-path diagnostic. Cheap, immediately valuable, and correct under every option in §5.1.
   This is what plan Part 3 adds. Note the registration-side check needs care: it must distinguish
   "unrelated plugin took the name" from "same plugin, new version", and a bad heuristic that fires
   on every legitimate redeploy is worse than none — so the deploy gate carries the weight.
2. **Separate rendering from identity** (§5.2). Independently useful: it is what makes charset and
   length limits a framework concern instead of a per-namespace surprise, and it is a precondition
   for any qualified identity.
3. **Qualify identity** (§5.1 option B), with existing bare names treated as an implicit unscoped
   publisher so deployed registry rows keep their key. Changing the Plugin aggregate's key is a hard
   migration — existing rows become unreachable — so the compatibility arm is not optional.
4. **Reference indirection and install-time aliasing** (§5.1 option A, §5.3), when installing plugins
   the platform did not author is a real requirement rather than an anticipated one.

Steps 1 and 2 stand on their own merits and should not wait for a decision on 3 and 4.

## 7. Open questions

- Does provenance (publisher, package, source) belong on the plugin definition regardless of whether
  identity is qualified? It is useful for attribution and audit even under bare names, and it is what
  a later qualification step would derive from.
- Should the registry record the *author's* name alongside the local identity, so a reference
  expressed in the author's terms stays resolvable after aliasing? Probably yes — it is the mapping
  of §5.3 stored where the resolution happens.
- Is there any legitimate case for two plugins deliberately sharing a *rendered* namespace while
  keeping separate identities? None found; recording the question because §5.2's derivation would be
  where it surfaced.
