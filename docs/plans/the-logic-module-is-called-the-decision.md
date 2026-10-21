# Plan: the write-side logic module is called the decision

**Status:** 📋 Planned 2026-10-21. Not started.<br/>
**Derived from:** [framework-vocabulary-behavior-chapter-and-doubled-terms.md](../analysis/framework-vocabulary-behavior-chapter-and-doubled-terms.md),
[§3](../analysis/framework-vocabulary-behavior-chapter-and-doubled-terms.md#3-behavior-or-decision)
and [§8.4](../analysis/framework-vocabulary-behavior-chapter-and-doubled-terms.md#84-recommendation);
decisions [D1, D2 and D6](../analysis/framework-vocabulary-behavior-chapter-and-doubled-terms.md#15-decisions).<br/>
**Touches:** `reventless/spec`, `reventless/core`, `reventless/gwt`, `reventless/aws`,
`reventless/local`, `packages/reventless-ppx`, every example and trait, `packages/doc`,
`CLAUDE.md` and `.claude/rules/`.

## In plain words

A write-side component is two files: the spec with its types, and a second file with the logic
that decides whether a command goes through. That second file is called the *behavior* today
(`AddProduct_Behavior.res`, `@@reventless.behavior`). Its main function is `decide`, and the
docs and logs already talk about the *decision model* and the *decision query*. This plan renames
the file and everything that names it to *decision*, so the file is called what it does.

The rename is hard: there is no alias. An old spelling stops compiling with a message that names
the new one and the codemod that makes the change. The analysis gives the reasons
([§3.5](../analysis/framework-vocabulary-behavior-chapter-and-doubled-terms.md#35-a-hard-rename-with-loud-refusals-not-aliases)).
The test step `thenRefused` becomes `thenForbidden` in the same commit, because it lives in the
same DSL and the same test files.

## Goal

After this plan, in this repo:

- every write-side logic file is `<Spec>_Decision.res`, annotated `@@reventless.decision`;
- the module type is `Reventless.Decision.T`, the test DSL `Decision_GWT`, the access step
  `thenForbidden`;
- an old spelling anywhere is a build error that says what to write instead;
- a downstream application moves with one command: the codemod in [R6](#r6-the-codemod).

Not in scope: the kind folders (`StateChange/` stays), the slice module types
(`StateChangeSlice` stays), `evolve`, `decide`, `initialState`.

## Phases

All phases land in **one commit** with the PPX republished in lockstep, because a PPX that
reads `@@reventless.decision` and a spec package that still exports `Behavior.T` cannot be
released apart. The phases are the order of work inside that commit.

### R1. Spec and core

- `reventless/spec/src/types/Behavior.res` becomes `Decision.res`; `module type T` keeps its
  shape. Update its doc comment: it implements the *decider* pattern.
- `reventless/core/src/Behavior.res` becomes `Decision.res` and includes `Reventless.Decision`.
- `ComponentKind.bodySuffixes` replaces `_Behavior` with `_Decision`.
- `StateChangeSlice.res` and every other reference to `Behavior.T` follow.
- No `module Behavior = Decision`.

### R2. The PPX

- `Vocabulary.ml`: the mode `decision` replaces `behavior`, with the same injections
  (`open Spec`, `module Spec = Spec`, `let moduleUrl`, the snapshot default).
- `@@reventless.behavior` is a compile error: *"renamed to `@@reventless.decision`; rename this
  file to `<Spec>_Decision.res` (or run `reventless-rename-to-decision`)"*. Follow the shape of
  `check_no_legacy_status_attr` in `StateAnnotations.ml`.
- Spec-name derivation strips `_Decision` where it strips `_Behavior` today.
- `GwtInference.ml`: `Decision` is the kind word and `_Decision` the filename hint; a
  `Behavior_GWT` reference or a `Behavior` kind word is refused with the same kind of message.
- `SidecarEmit.ml`: the kind label becomes `"Decision"`; the step that records sidecar kind
  `forbidden` reads `thenForbidden`.
- Every other `.ml` file that matches `behavior` (`AuthorizationInjection`, `OwnerInference`,
  `SensitiveInference`, `SnapshotInjection`, `TypeAnnotationInjection`, `Util`) follows.
- Build locally (opam switch 5.2.1), copy the binary to the gitignored `ppx-osx.exe`, and
  `touch` the `.res` files so no stale post-PPX AST survives.

### R3. The generator

- `Discovery.res` pairs a spec with `<Spec>_Decision.res`.
- A `<Spec>_Behavior.res` beside a spec is an error naming the file, the new name and the
  codemod. It is never classified as a component of its own.

### R4. The GWT package

- `Behavior_GWT.res` becomes `Decision_GWT.res`; no alias module.
- `thenRefused` becomes `thenForbidden` in every DSL that has it. No alias: a call to
  `thenRefused` fails to compile, and the compiler names the missing value.
- The framework's own GWT tests follow.

### R5. Runtime wiring

- `PluginRuntime_Builder.res`: `behaviorPath` becomes `decisionPath`,
  `registerStateChangeSliceSpec(~specPath, ~decisionPath)`.
- `AggregateRuntime_Builder_Single.res`: `behaviorModulePath` becomes `decisionModulePath`, and
  the runtime configuration's JSON key `behaviorModule` becomes `decisionModule`.
- `DcbCommandTopicEntryPoint_Ops.res` and the local runtime follow.
- The key is written and read by the same deploy, so no stored data changes.

### R6. The codemod

A bin in `reventless-spec`, `reventless-rename-to-decision`, written in ReScript on
`Reventless.CliArgs` like every other bin:

- walks a directory (default `.`), skipping `node_modules` and `lib`;
- `git mv`s every `*_Behavior.res` to `*_Decision.res`, falling back to a plain rename outside
  a git work tree;
- in `.res` files, replaces `@@reventless.behavior` with `@@reventless.decision`,
  `Behavior_GWT` with `Decision_GWT`, `Reventless.Behavior` with `Reventless.Decision`,
  `thenRefused` with `thenForbidden`, and module references to `<Spec>_Behavior` with
  `<Spec>_Decision`;
- `--dry-run` prints what it would do and changes nothing;
- exits 0 when it changed or would change files, 1 on a failure, 2 on a usage mistake.

Its tests run it over a fixture tree and compare the result.

### R7. Examples, traits and the platform's own files

- Run the codemod over `examples/`, `traits/` and `reventless/`. That covers the 48
  `_Behavior.res` files, including `PluginBehavior.res` (becomes `PluginDecision.res`) and
  `UiFragmentRegistry_Behavior.res`.
- Tracked `.res.mjs` outputs move with their sources: `git mv` the output too, then build so it
  is what the source compiles to. Check `git ls-files --deleted` afterwards.
- Re-run `generate-plugin` in every plugin so each committed `src/Plugin.res` names the new
  modules.
- `Platform.res` in `reventless-aws` names `ReventlessCore.UiFragmentRegistry_Decision`.

### R8. Docs and conventions

- Glossary: replace *Behavior* with *Decision*: the logic file of a write-side component,
  implementing the decider pattern, with one line saying it was called *Behavior* before.
- The "Step 2: Implement the Behavior" tutorial, the PPX page, `rescript-syntax.md`, the
  platform guide, the component pages, the GWT guide.
- The ten "Runtime Behavior" headings become "At run time", so the plain word does not sit next
  to the former term.
- The doc examples that still write `let apply = (state, event)` or `let handle = (state,
  command)` use `evolve` and `decide`
  ([§11 of the analysis](../analysis/framework-vocabulary-behavior-chapter-and-doubled-terms.md#11-terms-that-need-a-definition-not-a-rename)).
- `CLAUDE.md` and `.claude/rules/app-developer.md`: the file-naming table, the PPX annotation
  list, the GWT section, the `thenRefused` mention under the owner marker.
- The release notes name the codemod.

## Verification

```bash
pnpm run build 2>&1 | grep -E "Warning|warning|error|Error"   # nothing
pnpm test && pnpm run test:projects
pnpm run check:fresh-outputs
pnpm run check:lifecycle && pnpm run check:dcb-scope && pnpm run check:graphql
pnpm run check:traits
pnpm run format:res
```

- No residual token outside the refusal messages, the codemod and the glossary's former-name
  line:
  `git grep -nE "_Behavior|reventless\.behavior|Behavior_GWT|Behavior\.T|behaviorPath|behaviorModule|thenRefused"`.
- A fixture file still written with `@@reventless.behavior` fails the build with the refusal
  message, and so does a `_Behavior.res` beside a spec.
- The codemod, run over a copy of an example plugin taken before the rename, produces the
  committed tree.
- One example deploys and answers a command on the alpha stack, which proves the runtime
  configuration key.

## Risks

- **Tracked outputs.** `rescript clean` and a careless rename can drop tracked `.res.mjs`
  entry points; `check:fresh-outputs` and `git ls-files --deleted` catch it.
- **Stale PPX output.** After swapping the PPX binary, touch the sources, or the build reuses
  ASTs the old binary produced.
- **The build chain.** The root `build` is an ordered chain of `rescript build` invocations;
  a renamed module the chain's last step does not re-emit drops test coverage silently.
  `test:projects` fails if a jest project finds no suites.
- **Breaking for every consumer.** The commit is `feat!`. On a prerelease line that does not
  bump the major, so the release notes must say it in words.
