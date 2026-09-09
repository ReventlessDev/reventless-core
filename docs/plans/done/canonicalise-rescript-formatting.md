# Plan: canonicalise ReScript formatting

**Date:** 2026-09-09
**Status:** Done — 2026-09-09. See *Outcome* at the foot.
**Scope:** this repo only. Every step is self-contained; nothing here depends on another
repository.

## Problem

`rescript format` is a whole-file reprinter. Run it on a file whose stored text differs from
what the formatter would emit and it rewrites *the whole file*, not the part anyone edited.
**57% of the ReScript sources in this repo are in that state.** So:

- an editor with format-on-save turns a two-line edit into a hundred-line diff;
- a collaborator who does *not* format writes in the file's existing local style, which the
  next save reformats;
- the two behaviours alternate on the same file, and every alternation is churn — unreadable
  diffs, review noise, and real merge conflicts wherever the reflow touches lines a parallel
  branch also touched.

Nothing in the repo states a position: no `.vscode/settings.json` entry mentions
`editor.formatOnSave`, and no CI workflow runs `rescript format --check`. Formatting is
currently an *unowned* decision with two producers and no canonical form, and the only thing
holding the churn back is a hand-written instruction telling one collaborator not to run the
tool the ecosystem assumes everyone runs.

The fix is to make the stored text canonical once, then enforce it. After that, formatting and
not-formatting converge on the same bytes and the class of problem ends.

## Measured state (2026-09-09)

| | count |
|---|---|
| tracked `.res` / `.resi` | 1718 |
| excluded (see below) | 1 |
| checked | 1717 |
| **not formatter-canonical** | **984 (57%)** |
| lines that would move | **~57,100** |

Worst files, by lines moved:

| lines | file |
|---|---|
| 2596 | `reventless/core/tests/plugin/PluginStructureTest.res` |
| 2347 | `reventless/core/tests/api/SuryToJsonSchemaTest.res` |
| 1920 | `reventless/core/src/components/Dcb/Dcb_Builder.res` |
| 1234 | `reventless/local/tests/adapter/GraphQL_SchemaInspectorTest.res` |
| 687 | `reventless/core/src/plugin/component/Plugin_Structure.res` |
| 649 | `reventless/aws/src/Platform.res` |
| 641 | `reventless/core/tests/dcb/DcbStateChangeSliceTest.res` |
| 638 | `reventless/local/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res` |

The distribution matters: the files under active work are the large ones, which are also the
worst affected. Re-measure before starting — the numbers drift with every commit:

```bash
pnpm run format:res:check    # after step 1
```

Two facts make this a one-off rather than a recurring bill:

- **The formatter is idempotent.** `format(format(x)) == format(x)`. Canonicalise once and the
  state holds.
- **One formatter, one version.** `rescript-legacy` is not an older compiler; it is a build
  orchestrator inside the same `rescript` package (12.3.0 here). Both CLIs produce
  byte-identical output on the same input, so "canonical" is unambiguous.

## What is excluded, and why

**`docs/templates/deploy-aws/plugin-Main.res`** — a scaffold template carrying
`{{PLUGIN_NAME}}` / `{{PLUGIN_MODULE}}` placeholders. It is not valid ReScript and
`rescript format` fails on it with a syntax error. Left in the set it would make the CI guard
permanently red.

`docs/templates/deploy-aws/platform-Main.res` has no placeholders, parses fine, and stays in
the set.

Nothing else is generated output in this repo — there is no `__generated__` tree.

## Steps

### 0. Preconditions

- **Clean working tree.** The reformat touches almost everything; uncommitted work will be
  impossible to separate from it afterwards. The tree currently has modified files under
  `reventless/seed*` — land or stash those first.
- **No long-lived branch open.** Any branch created before the reformat and merged after it
  eats a whole-tree conflict. This is the one genuinely disruptive property of the change, and
  the only mitigation is timing.
- Land this on its own. Never mixed into a functional change.

### 1. Wire the file set once

The file set has to be identical in the one-off, in CI, and in whatever anyone runs by hand —
otherwise the exclusion drifts and the guard fails on files nobody was supposed to touch. Put
it in `package.json` and let everything call that:

```json
"format": "pnpm run format:res",
"format:res": "git ls-files -z '*.res' '*.resi' ':(exclude)docs/templates/deploy-aws/plugin-Main.res' | xargs -0 -r -n 300 rescript format",
"format:res:check": "git ls-files -z '*.res' '*.resi' ':(exclude)docs/templates/deploy-aws/plugin-Main.res' | xargs -0 -r -n 300 rescript format --check",
```

Notes:

- The existing `"format": "rescript format"` is repointed deliberately. Bare `rescript format`
  takes its file set from the project config, which does *not* honour the exclusion — it is the
  footgun this plan exists to remove.
- `-n 300` is required: the full list exceeds `ARG_MAX` in this repo and an unbatched `xargs`
  splits it in a way that silently drops output.
- `-r` keeps an empty list from invoking `rescript format` with no arguments, which would
  format everything the project config knows about, exclusion included.

Commit this together with step 5 (the editor setting). No source files move yet, so CI stays
green.

### 2. The reformat commit

```bash
pnpm run format:res
pnpm run format:res:check           # MUST be clean before committing — see below
git status --short | wc -l          # expect ~984 modified .res/.resi
```

**Run the formatter until the check is clean, not once.** `format(format(x)) == format(x)` holds
for a file that is already canonical, but a single pass does not always reach the fixpoint *from*
a non-canonical one: a trailing comment inside a call argument can need two passes to settle onto
its own line. It converges — this is a fixpoint reached in two iterations, not a cycle — but
commit the one-pass output and CI goes red on a file the formatter itself just wrote.

Commit as a single mechanical change, nothing else in it:

```
style(rescript): reprint every source through the formatter

The sources were not formatter-canonical, so a formatting editor rewrote
whole files for one-line edits while a non-formatting one wrote in each
file's local style. No behaviour change.
```

### 3. `.git-blame-ignore-revs`

The reformat commit's SHA only exists once step 2 is committed, so this is a follow-up commit.
Create `.git-blame-ignore-revs` at the repo root:

```
# Whole-tree formatter reprint, no behaviour change.
<sha of the step-2 commit>
```

GitHub reads this file from the default branch automatically. Local clones need opting in
once, which is not something the repo can do for you:

```bash
git config blame.ignoreRevsFile .git-blame-ignore-revs
```

Add that line to whatever the repo's setup path is (`scripts/setup.mjs` is the natural home)
so a fresh clone picks it up. Treat the file as **append-only**: every future re-canonicalisation
adds a line, and rewriting the step-2 commit silently invalidates the entry.

**Set the config before the reprint lands, not after.** GitLens supports the file — it passes
`--ignore-revs-file` — but caches the resolution for two hours (`accessTTL: 72e5`) on top of its
per-document blame cache. Configure it afterwards and the editor keeps crediting reprinted lines
to the reprint for hours while command-line `git blame` is already correct, which looks exactly
like the ignore file not working. `Developer: Reload Window` clears it.

**Calibrate what this file actually buys — it is less than it looks.** Git's own content matching
already credits the original author for the large majority of reprinted lines, unaided. What
defeats blame is not the reprint per se but *re-indentation*, which turns short generic lines
(`)`, `| _ =>`, a bare identifier) into whitespace-only changes git cannot uniquely match — and
`--ignore-revs-file` cannot recover those either, because the line's content did not exist in the
parent. The lever that recovers them is whitespace-insensitive blame (`git blame -w`, and the
editor setting in step 5), not this file. Keep the file regardless: GitHub's web blame reads it
independently of local config and it costs nothing. But if a line still blames to the reprint,
check the editor's whitespace setting and cache before suspecting this.

### 4. The CI guard

Without this the tree drifts straight back and the bill is paid twice. In
`.github/workflows/ci.yml`, job `build-and-test`, insert a step immediately after
**Install dependencies** and before **Build all packages** — it needs `node_modules`, it takes
well under a second, and failing there is cheaper than failing after the build:

```yaml
      # A non-canonical source makes rescript format rewrite the whole file on
      # the next save, so a one-line edit lands as a hundred-line diff and
      # collides with anything touching the same region. Keep the tree canonical.
      - name: Check ReScript sources are formatter-canonical
        run: pnpm run format:res:check
```

Do not gate it on the affected-projects detection — it is cheap and the whole point is that it
covers everything.

### 5. State the position in the editor config

**First: `.vscode` is ignored wholesale (`.gitignore` line 5), so nothing in this step can be
committed as things stand.** Git does not descend into an ignored directory, so a negation on its
own is inert — the directory pattern itself has to give way:

```
.vscode/*
!.vscode/settings.json
```

That keeps every other file in `.vscode/` ignored exactly as before. Then append to
`.vscode/settings.json`:

```json
  "[rescript]": {
    "editor.formatOnSave": true
  },
  "gitlens.blame.ignoreWhitespace": true
```

Once the tree is canonical the first is correct for everyone, and committing it makes the position
a repo fact rather than a per-user accident. Commit with step 1.

**The second line is what actually protects `git blame` through the reprint** — more than step 3
does. GitLens defaults `blame.ignoreWhitespace` to **false**, so out of the box it credits every
re-indented line to the reprint. Turning it on moves roughly two thirds of those lines back to
whoever wrote them; what survives is bracket and blank lines, which nobody selects. Reload the
window after committing it, since the setting is read once and cached.

### 6. Verification

The formatter is a reprinter, but a 57k-line commit deserves the check:

```bash
pnpm run build
pnpm run test
pnpm run check:outputs
```

Then confirm the compiled outputs did not move:

```bash
git status --short -- '*.res.mjs'   # expect empty
```

This repo tracks 1178 `.res.mjs` files. Compiled output carries no source line references, so
a reprint should not change a byte of it — but if anything *does* appear here it must go into
the step-2 commit, not be left for the next unrelated change to pick up.

**Do not run `pnpm run clean` or `rescript clean` as part of this.** Cleaning under
`examples/` cascades into deleting tracked `.res.mjs` outputs. Build and test only.

## Release blast radius

`release.yml` and `release-packages.yml` run off CI success on `alpha`, and `lerna.json`
`ignoreChanges` covers `**/*.md` and `**/test/**` / `**/tests/**` — but **not** `src/**`. A
whole-tree reprint therefore marks nearly every package changed, and these publish publicly to
npmjs.

Before pushing, dry-run the versioning to see exactly what would be cut:

```bash
pnpm exec lerna changed
pnpm exec lerna version --no-git-tag-version --no-push
```

A wave of no-op patch releases is a real cost to consumers who pin. Decide deliberately whether
to absorb it or to hold the push until a release is wanted anyway; do not discover it from the
workflow log.

## Ordering and push

Three commits, one push:

1. tooling — `package.json` scripts + `.vscode/settings.json` (steps 1, 5)
2. the reprint (step 2)
3. `.git-blame-ignore-revs` + the CI guard (steps 3, 4)

CI only runs on the pushed head, so the intermediate states never go red. Push once, after all
three exist and step 6 passes locally.

## Rollback

Step 2 is a pure reprint with no behaviour change, so `git revert` of that one commit restores
the previous bytes exactly. Revert the step-3 commit with it, or the CI guard will fail against
the un-canonical tree.

## Follow-ups

- **A compiler upgrade that changes the printer re-opens this.** The canonical form is a
  function of the `rescript` version. When it moves, some fraction of the tree goes
  non-canonical at once and this CI guard goes red across the board. That is a bounded,
  repeatable event — reprint, append the new SHA to `.git-blame-ignore-revs` — but it belongs
  in the upgrade runbook, not in a surprise red build.
- **Every new generator needs an exclusion.** Any future tool that emits tracked `.res` must be
  added to the pathspec in step 1, or its output is either reformatted (and un-formatted again
  on the next generate) or fails the guard.
- The standing "never run `rescript format`" instruction becomes "format what you touch" once
  this lands. Leaving it stale reintroduces the mixture from one side.
- The tracked `.res.mjs` outputs are the same defect in a different extension — a derived form
  of the file stored in git with more than one producer. Worth the same treatment separately.

## Outcome (2026-09-09)

Executed as three commits. 1001 of 1718 files were non-canonical (the plan
measured 984; the tree had moved). Two passes were needed to reach the fixpoint,
exactly as step 2 warned — 20 files still moved after the first.

Two of the plan's assumptions turned out to be wrong, both worth recording:

- **"Pure reprint, no behaviour change" is not true of this formatter.**
  `rescript format` strips the parentheses from a ternary used as another
  ternary's condition, so `(a ? b : c) ? d : e` was reprinted as
  `a ? b : (c ? d : e)` — a different program. One occurrence, in
  `reventless/aws/src/Platform.res`; the branch types differed so the compiler
  caught it, but with matching types it would have been silent. Rewritten as a
  `let` binding, which round-trips. A repo-wide scan across line breaks found no
  other instance. Note that the obvious single-line grep **misses** this shape.
- **"Compiled output carries no source line references" is not true either.**
  `__LOC__` expands to one, so `Util_Promise.res.mjs` moved when the reprint
  moved its line. Both `.res.mjs` movements went into the reprint commit as the
  plan required.

Deviation from step 4: the CI guard carries the same
`if: steps.affected.outputs.select != 'none'` as every other step in the job.
It needs `node_modules`, and when nothing is affected there is no install — and
no build or test either, so the guard is not weakened relative to the rest.

Verification: build green with zero warnings, 400 suites / 4342 tests passing,
and `check:outputs`, `check:graphql`, `check:unions`, `check:resolvers`,
`check:slots`, `test:projects` all green.

The release blast radius under *Release blast radius* was **not** exercised —
the three commits are unpushed, so that decision is still open.
