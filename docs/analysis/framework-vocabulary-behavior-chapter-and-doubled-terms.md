# Framework vocabulary: behavior, chapter, and other doubled terms

**Status:** Analysis, 2026-10-18. Nothing renamed yet. The open decisions are listed in
[§8](#8-decisions).

**Relates to:** [event-terminology-disambiguation.md](event-terminology-disambiguation.md)
(the earlier pass over "event" and "handler"),
[mapping-harmonization.md](mapping-harmonization.md) (the mapping body files),
[docs/plans/done/deployed-chapter-grouping.md](../plans/done/deployed-chapter-grouping.md)
(how the chapter became a deployed datum),
[.claude/rules/app-developer.md](../../.claude/rules/app-developer.md) (the file-naming table).

---

## In plain words

A framework is learned through its words. When one thing has two names, or one name means two
things, every reader pays a small toll each time, and tools built on the framework have to pick a
side. This analysis looks at the framework's vocabulary as it stands today and asks two
questions the maintainers raised, then sweeps the rest of the vocabulary for the same kind of
problem.

The two questions:

1. **Behavior or decision?** The module that holds a write-side component's logic is called its
   *behavior* (`Product_Behavior.res`, `@@reventless.behavior`, `Behavior.T`). Its main function
   is `decide`, the state it builds is the *decision model*, and everything around it, from the
   docs to the log events, already talks about decisions. Should the module be called the
   *decision*?
2. **Chapter or section?** A plugin's components are grouped into bands (`src/Product/`,
   `src/Order/`). The framework calls a band a *chapter*. Plain-language surfaces built on the
   framework sometimes say *section*. Which word should be used everywhere?

The short answers: rename *behavior* to *decision*, in one coordinated change with a
compatibility window ([§3.6](#36-recommendation)); keep *chapter* everywhere and treat *section*
as a word already taken by two other things ([§4.4](#44-recommendation)). The sweep in
[§5](#5-other-doubled-terms) finds a few more doubled terms, most of them deliberate layering
rather than drift, and [§6](#6-spelling-behaviour-and-behavior) finds the one true inconsistency
nobody decided: the repo spells *behaviour* and *behavior* about half and half.

---

## 1. Scope and method

Counts below come from a search over `reventless/*/src`, `examples/`, `traits/`,
`packages/reventless-ppx/src`, `packages/doc`, and `docs/`, excluding `node_modules`, `lib`,
and compiled `.res.mjs` files. They are rough and meant to show weight, not to be exact.

| Term | Where it lives | Files (this repo) |
|---|---|---|
| `Behavior` as an identifier (`_Behavior.res`, `@@reventless.behavior`, `Behavior.T`, `Behavior_GWT`, `behaviorPath`) | spec, core, gwt, aws, ppx, examples, traits, docs | ~250 |
| *behavior* / *behaviour* as a plain English word | prose and comments | ~570 + ~580 word hits |
| `decide` / *decision* | spec, core, docs | ~120 + ~120 word hits in `src` alone |
| `chapter` (`queryableDef.chapter`, `componentChapters`, docs) | spec, core, ppx-free, docs | ~100 |
| *section* | prose: document sections, list-view sections | 25 hits in `src`, none naming a chapter |

---

## 2. How the framework names a write-side component today

A write-side component is two files in one kind folder. The folder names the kind, the first file
holds the types, the second the logic:

```
Aggregate/Product.res            ← Spec: command, event, error types
Aggregate/Product_Behavior.res   ← Behavior: state, initialState, evolve, decide

StateChange/AddProduct.res           ← Spec
StateChange/AddProduct_Behavior.res  ← Behavior
```

Both kinds implement the same module type,
[`Behavior.T`](../../reventless/spec/src/types/Behavior.res): a `state`, an `initialState`, an
`evolve` that folds one event into the state, and a `decide` that takes the state and a command
and answers with events or an error. The read-side body files follow the same `<Spec>_<Word>`
pattern with a word that names what the file holds: `_Projection` (one projection), `_Projections`
(a list of mappings), `_Translation`, `_Automation`, `_Mappings`
([`ComponentKind.bodySuffixes`](../../reventless/spec/src/components/ComponentKind.res)).

Of the 48 behavior files in this repo, 37 sit in `StateChange/` folders, 7 in `Aggregate/`, and the
rest are the framework's own (the platform's plugin aggregate
[`PluginBehavior.res`](../../reventless/core/src/plugin/lifecycle/PluginBehavior.res), the UI
fragment registry slice, and test fixtures).

---

## 3. Behavior or decision

### 3.1 What "behavior" names, and where

| Surface | Spelling | File |
|---|---|---|
| Module type | `Behavior.T` | [spec `types/Behavior.res`](../../reventless/spec/src/types/Behavior.res), re-exported by [core `Behavior.res`](../../reventless/core/src/Behavior.res) |
| Slice module type | `StateChangeSlice.T` embeds the same three functions | [`StateChangeSlice.res`](../../reventless/spec/src/components/StateChangeSlice.res) |
| File suffix | `_Behavior` | [`ComponentKind.bodySuffixes`](../../reventless/spec/src/components/ComponentKind.res), the generator's [`Discovery.res`](../../reventless/spec/src/generator/Discovery.res) |
| PPX attribute | `@@reventless.behavior` | [`Vocabulary.ml`](../../packages/reventless-ppx/src/ppx/Vocabulary.ml) and eight more `.ml` files (128 mentions) |
| GWT DSL | `Behavior_GWT` (aggregates and slices alike, since the legacy `StateChangeSlice_GWT` was folded in) | [`Behavior_GWT.res`](../../reventless/gwt/src/Behavior_GWT.res) |
| PPX GWT inference | `Behavior` as a `<Kind>` word and `_Behavior` as a filename hint | [`GwtInference.ml`](../../packages/reventless-ppx/src/ppx/GwtInference.ml) |
| Deploy-time runtime wiring | `behaviorPath`, `behaviorModulePath`, the JSON key `behaviorModule` in the Lambda runtime configuration | [`PluginRuntime_Builder.res`](../../reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res), [`AggregateRuntime_Builder_Single.res`](../../reventless/aws/src/adapter/Runtime/AggregateRuntime_Builder_Single.res) |
| GWT sidecar | a `"Behavior"` kind label in the untracked `*.gwt.json` | generated per test run |
| Docs | glossary entry *Behavior*, the "Step 2: Implement the Behavior" tutorial, the PPX page, ~380 word mentions | [`glossary.md`](../../packages/doc/docs-app/glossary.md) |

### 3.2 What already says "decision"

- The function is `decide`. Its sibling helpers are `decideActing` (ownership refusal),
  `decideRetired`, `decideRelease`. There are 121 `decide*` identifiers in `src`.
- The glossary defines a **decision model**: "the ephemeral state a write-side component builds by
  replaying the events relevant to one command, folding them with `evolve` from `initialState`".
  That *is* the behavior module's `state`, built by the behavior module's `evolve`. The log events
  are `DecisionModelCacheHit`, `DecisionModelCacheMiss`, `DecisionModelDeltaEventCount`.
- A DCB slice's read of the event log is the *decision query* and its tags the *decision read*
  ([`DcbTag.res`](../../reventless/spec/src/components/DcbTag.res)).
- The pattern the module type implements, `{initialState, evolve, decide}`, is known in the
  event-sourcing community as the **decider** pattern. Nothing in the repo uses that name.

So the word *behavior* is the odd one out. A reader learns "the decision model is built by
`evolve` in the behavior module and handed to `decide`", which is three words for one idea.

### 3.3 What else "behavior" means here

- Plain English. Ten docs pages have a "Runtime Behavior" heading about how a component acts at
  run time, which has nothing to do with the behavior module. The AWS stack has
  `orderedCacheBehaviors` (CloudFront's word). Comments say "the deployment's behaviour".
- The spelling is split: 570 *behaviour* against 580 *behavior* across source and docs. An
  identifier can only be spelled one way, so every prose mention near code has to choose between
  matching the identifier and matching the house style. [§6](#6-spelling-behaviour-and-behavior)
  has the numbers.

Once the module is called *decision*, the plain word *behaviour* is free for prose and the
collision disappears.

### 3.4 Pros and cons

**For renaming to decision**

- The name says what the file does. `decide` is the one function a reader opens the file for;
  `evolve` and `initialState` exist to feed it.
- One word instead of three. *Decision model*, *decision query*, `decide*` and the file all line
  up: the decision module builds the decision model and decides.
- *Behavior* stops being overloaded with its plain-English meaning and the spelling split loses
  its hardest case.
- The body-file convention stays intact: `_Decision` is a noun for what the file holds, like
  `_Projection`, `_Translation`, `_Automation`.
- Plain-language surfaces that describe a write-side slice as "something that gets decided" meet
  the framework's own word a step earlier.

**Against**

- It is the widest rename the repo has done. The comparable slice-folder rename
  (commit `a40055512`, 2026-09-07) touched 379 files. This one touches the PPX, the generator,
  the GWT package, the AWS runtime builders, every example and trait, the docs, and the
  published PPX binary.
- *Decision* already carries the plain-language meaning of a whole write-side slice (spec plus
  logic), not just its logic half. After the rename, "the AddProduct decision" names the slice
  in conversation and `AddProduct_Decision.res` names its logic file. The two readings nest
  rather than conflict, but the docs must say so once.
- *Decision* is an outcome noun. *Decider* is the agent noun the community uses for the pattern.
  See [§3.5](#35-alternatives).
- `@@reventless.behavior` is in every downstream application's source. A window where both
  spellings compile is needed, and the PPX must be republished in lockstep with the core packages
  (the drill in [ppx-republish-single-commit.md](../plans/done/ppx-republish-single-commit.md)).
- The platform's own `PluginBehavior.res` is a behavior file by the same rule and renames too.

### 3.5 Alternatives

| Option | Verdict |
|---|---|
| **`_Decision`, `@@reventless.decision`, `Decision.T`, `Decision_GWT`** | Recommended. Fits the body-suffix convention (a noun for what the file holds) and the existing *decision model* / *decision query* words. |
| `_Decider` | Names the pattern exactly, and only this file would carry an agent noun (`_Projection`, not `_Projector`; `_Translation`, not `_Translator`). Mention *decider* in the glossary as the pattern name; do not use it as the suffix. |
| Keep `Behavior` | Costs nothing now and keeps paying the three-words toll. Defensible only if no other rename is planned, because the compatibility window is the expensive part and is best shared. |
| Rename the `StateChange/` folder to `Decision/` as well | No. *State Change*, *State View*, *Automation* and *Translation* are the established slice names of the modelling method the framework follows, and the folder word names the kind, not the file. The plain word for the kind stays a gloss on the kind, not a replacement. |
| Rename `evolve` to `apply` or `fold` | No. `evolve` is the decider pattern's own word and is consistent across aggregate and slice. |

### 3.6 Recommendation

Rename *behavior* to *decision* everywhere it names the write-side logic module, as one
coordinated change:

1. **Spec and core.** `Behavior.res` becomes `Decision.res` with `module type T` unchanged in
   shape; `Reventless.Behavior` stays as a deprecated alias (`module Behavior = Decision`) for
   one release window. `ComponentKind.bodySuffixes` gains `_Decision` and keeps `_Behavior` so the
   stem-collision check still sees both.
2. **PPX.** `@@reventless.decision` is the new attribute; `@@reventless.behavior` is accepted
   and rewritten with a deprecation warning that names the file. The GWT inference accepts
   `Decision` and `Behavior` as kind words and `_Decision` / `_Behavior` as filename hints. The
   sidecar's kind label becomes `"Decision"`. Republish the PPX with the core packages.
3. **Generator.** Pair a spec with `_Decision` first, then `_Behavior`; emit an information line
   when it used the old suffix.
4. **GWT.** `Decision_GWT` with `Behavior_GWT` as an alias module.
5. **AWS runtime builders.** `behaviorPath` → `decisionPath`, the runtime JSON key
   `behaviorModule` → `decisionModule`. These are written and read by the same deploy, so no
   stored data changes and no migration is needed.
6. **Examples, traits, the platform's own files.** `git mv` every `_Behavior.res` and update its
   attribute. Refresh goldens in the same commit (lifecycle model, DCB scope, GraphQL goldens are
   not affected by a file rename, but run the checks).
7. **Docs.** Glossary: replace *Behavior* with *Decision* and say it implements the decider
   pattern; keep a one-line *Behavior (former name)* entry for a window. Rename the "Runtime
   Behavior" headings to "At run time" so the plain word does not sit next to the former term.
   Update the file-naming table in [app-developer.md](../../.claude/rules/app-developer.md).
8. **Remove the aliases** after the window, in a `feat!` commit.

Do not rename the kind folders, the slice module types (`StateChangeSlice`), or `evolve`.

---

## 4. Chapter or section

### 4.1 What a chapter is in the framework

A chapter is the first folder under `src/` that is not a kind folder: `src/Product/StateChange/`
puts `AddProduct` in the `Product` chapter. It began as a filesystem convention and became a
framework datum in [deployed-chapter-grouping.md](../plans/done/deployed-chapter-grouping.md):

- every component definition carries `chapter: option<string>`
  ([`Plugin.res`](../../reventless/spec/src/components/Plugin.res), on `queryableDef`,
  `commandDef`, and the others), and the generated `Plugin.res` lists `componentChapters`;
- the platform's component-definitions API and the UI manifest publish it, so a consumer that
  renders the plugin from deployed read models groups components the same way the source does;
- the DCB partition inference reads it: when a slice's events carry more than one id, "the ids
  every event in the slice's chapter carries" break the tie, so `PlaceOrder` under `Order/` is
  partitioned by `orderId` ([`DcbScopeInference.res`](../../reventless/spec/src/components/DcbScopeInference.res),
  [dcb-usage.md](../../packages/doc/docs-app/dcb-usage.md)). Moving a slice between chapters can
  move its partition.

So *chapter* is not a label. It is a semantic grouping the framework acts on, with ~100 files in
this repo using the word and no other word for it in code. The modelling method the framework
follows also calls this grouping a chapter, so the word is learnable from outside the framework.

The gap on the framework's side: the docs glossary has no *Chapter* entry.

### 4.2 What "section" already means

*Section* is a common word and the repo already uses it for two things that are not chapters:

| Meaning | Where |
|---|---|
| A list view's row groups, keyed by the `@groupBy` field ("AutoUI sections the admin Plugins view by kind") | [`PluginsReadModelSpec.res`](../../reventless/core/src/plugin/lifecycle/PluginsReadModelSpec.res), [`StateAnnotations.res`](../../reventless/spec/src/components/StateAnnotations.res), the UI library's list and detail views |
| A section of a document (every `§` link in `docs/`, the SDL's `type Query` section, a JWT's payload section) | prose everywhere |

Authoring surfaces built on the framework add a third: the top-level lists of an app's definition
file (its stories, actors, identities, types, components, scenarios) are its *sections*, and in
the same surfaces a chapter is labelled "a section of *System*". A reader of such a surface meets
*section* with three referents on one screen.

### 4.3 Pros and cons

**For chapter everywhere**

- It is already everywhere in the framework. Zero code changes here; the work is on the surfaces
  that chose *section* as a gloss.
- It is specific. *Chapter* has one meaning in the framework and one in the modelling method,
  and the two agree. *Section* has at least three.
- Developers, the docs, the generated map, and the deployed manifest all say *chapter*. A person
  who learned *section* in a plain-language surface and then opens the source, the docs, or a
  pull request has to translate.
- The plain-language surfaces already gloss other framework words instead of replacing them
  (a StateChange slice is "something that gets decided", a plugin is "a separate system"). The
  same device, "a chapter: a part of *System*", keeps the word and explains it.

**For section in plain-language surfaces**

- *Chapter* is a book metaphor and *section* a document metaphor; neither is obviously friendlier.
  The case made for *section* was that it is the word a components tree already used, not that it
  reads better.
- An author who does not write code never sees the folder. For them the band is just a grouping,
  and any grouping word works until they meet the framework's word elsewhere.

**Against section as the framework's word**

- It would collide with the `@groupBy` sections in every list view, which are also groupings of
  rows under headings in the same UI.
- It would cost a rename of a deployed datum (`chapter` on every component definition, in the
  manifest and the component-definitions API) for no gain in meaning.

### 4.4 Recommendation

Use *chapter* everywhere a framework concept is named, including plain-language surfaces, and
reserve *section* for the two things it already means: a list view's row groups and a part of a
document. Concretely, in this repo:

1. Add a glossary entry **Chapter**: the first non-kind folder under `src/`, carried as `chapter`
   on every component definition, used by the UI to group components and by the DCB partition
   inference to break ties.
2. Keep the "section" wording for `@groupBy` and say so in the glossary entry, so the two words
   are defined against each other.

Surfaces outside this repo that gloss the word should gloss it as they gloss the other kinds, in
the form "a chapter, a part of *System*", rather than substituting *section*.

---

## 5. Other doubled terms

A sweep over the same sources for one thing with two names, or one name with two things. Most of
what it found is deliberate layering, listed in [§5.2](#52-deliberate-layering-leave-alone) so
nobody re-opens it. The rest is in [§5.1](#51-true-inconsistencies-with-a-verdict), each with a
verdict: **rename** (an identifier changes), **docs** (the code is fine, a doc or the glossary is
not), or **leave**.

### 5.1 True inconsistencies, with a verdict

| Id | What | Where | Verdict |
|---|---|---|---|
| R1 | The row key of a read model is `module Id`; the row key of a state view is `module Key`, for the same role | [`ReadModel.res`](../../reventless/spec/src/components/ReadModel.res) line 174, [`StateViewSlice.res`](../../reventless/spec/src/components/StateViewSlice.res) line 60 | **Rename** `Key` → `Id` on the state view, with `Key` kept as an alias for a window; the PPX injects `module Key = Reventless.Id.StringPure` today and would inject `Id`. *Key* was chosen to avoid the auto-injected `module Id` of the spec, so check that collision first; if it stands, rename the read model's instead. |
| R2 | *Refused* means three things: the umbrella `refusalCause = DomainRejection \| InfrastructureFailure \| AccessRefusal`; the GWT `thenRefused`, which is access refusal only (a domain rejection is `thenError`); the lifecycle harvest's `outcome = Refused`, which maps the sidecar's `"error"` kind, that is, a domain rejection | [`CommandTopic_Helpers.res`](../../reventless/core/src/components/CommandTopic/CommandTopic_Helpers.res) line 32, [`Behavior_GWT.res`](../../reventless/gwt/src/Behavior_GWT.res) line 278, [`CheckLifecycleModel.res`](../../reventless/spec/src/lifecycle/CheckLifecycleModel.res) lines 598 and 649 | **Rename** the harvest's `Refused` to `Rejected`, so *rejected* is the domain's no and *refused* the platform's no (access, infrastructure), matching the wire's `CommandRejected`. The umbrella type can stay; its arms already say which. |
| R3 | *Delegate* names the local event source in an extension-point mapping, the local command target in an extension, and the GWT kind for the whole boundary (`Delegate_GWT`); none is in the glossary | [`extensionpoint.md`](../../packages/doc/docs-app/components/extensionpoint.md), [`plugin-system.md`](../../packages/doc/docs-app/plugin-system.md), [`Delegate_GWT.res`](../../reventless/gwt/src/Delegate_GWT.res) | **Docs.** One glossary entry: "the local component an extension point or extension stands in for; on the publishing side its events, on the consuming side its commands". The code reading is consistent (the delegate is always the local side); the docs just never say it once. |
| R4 | *Port* is used for an extension point's translation table in two docs pages and the PPX, and is defined nowhere | [`extensionpoint.md`](../../packages/doc/docs-app/components/extensionpoint.md), [`extension.md`](../../packages/doc/docs-app/components/extension.md), [`TranslationTable.ml`](../../packages/reventless-ppx/src/ppx/TranslationTable.ml) | **Docs.** Either define *port* in the glossary as "an extension point or an extension, seen from outside the plugin" or replace the three uses with the component's name. Replacing is cheaper and adds no word. |
| R5 | The GWT DSL and module say *multi-source* (`MultiSourceProjection_GWT`); the docs pages say *mixed-source* (`mixed-source-readmodel.md`, `mixed-source-automationslice.md`), about 20 files each | [`MultiSourceProjection_GWT.res`](../../reventless/gwt/src/MultiSourceProjection_GWT.res), [`mixed-source-readmodel.md`](../../packages/doc/docs-app/mixed-source-readmodel.md) | **Docs.** Rename the two pages and their prose to *multi-source*; the identifier is the one that cannot move without a window. |
| R6 | Docs examples still write `let apply = (state, event)` and `let handle = (state, command)` where the framework's functions are `evolve` and `decide` | [`application-development-layers.md`](../../packages/doc/docs-framework/application-development-layers.md) lines 111 and 699, [`commandgenerator.md`](../../packages/doc/docs-framework/runtime-components/commandgenerator.md) line 86, [`rescript-syntax.md`](../../packages/doc/docs-app/rescript-syntax.md) line 119 | **Docs.** Four edits. Do them with the rename in [§3.6](#36-recommendation), which touches the same pages. |
| R7 | The terminology guide says "role, not piece", and the module it governs says *piece* eleven times in its own comments | [`terminology-guide.md`](../guides/terminology-guide.md) line 98, [`ResourceAttribution.res`](../../reventless/core/src/ResourceAttribution.res) lines 12, 43, 108 | **Docs** (comments). Replace *piece* with *role* in the comments; no identifier carries it. |
| R8 | The read-side body files pair a word with an attribute that says a different word: `_Projections` with `@@reventless.mappings`, `_Projection` with `@@reventless.projection`, `_Mappings` with `@@reventless.mappings` | [`Vocabulary.ml`](../../packages/reventless-ppx/src/ppx/Vocabulary.ml) lines 67 and 70, [`ComponentKind.res`](../../reventless/spec/src/components/ComponentKind.res) line 95 | **Leave**, but document. `@@reventless.mappings` names the shape (a list of per-source mappings, used by two file kinds) and the suffix names the output. The file-naming table should show the attribute column so the pairing is visible, instead of a reader inferring it. |
| R9 | The earlier proposal to rename the runtime's `eventHandler` (a platform invocation handler, not a domain event handler) was never applied | [`Runtime.res`](../../reventless/core/src/adapter/Runtime/Runtime.res) line 1, [event-terminology-disambiguation.md](event-terminology-disambiguation.md) | **Rename**, as that analysis proposes (`invocationHandler`, `'payload`). Internal to the runtime layer; no application code names it. |
| R10 | Framework GWT tests are `*GwtTest.res`, example tests `*_GWT.res`; the PPX accepts `_GWT`, `GwtTest` and `Gwt` | [`GwtInference.ml`](../../packages/reventless-ppx/src/ppx/GwtInference.ml), [`reventless/gwt/tests/`](../../reventless/gwt/tests/) | **Leave.** The framework's own tests are not the canonical form the docs teach, and the PPX's tolerance is cheap. Renaming them buys uniformity nobody reads. |

### 5.2 Deliberate layering, leave alone

Named here so the next sweep does not re-find them.

- **Aggregate style and DCB style run parallel vocabularies** on purpose: `ReadModel` /
  `StateViewSlice`, `_Projections` / `_Projection`, `EventMapping` / `AutomationSlice`, and the
  shared umbrella `queryableDef` / `writableDef` over both. The glossary's *Projection* entry
  describes the aggregate-style unit (one event-to-state mapping a read model composes), which is
  also what the DCB `_Projection.res` holds. Fine as is.
- **`StateChangeSlice` on types, `StateChange/` on folders.** Decided in
  [`ComponentKind.res`](../../reventless/spec/src/components/ComponentKind.res): the folder names
  the kind, the type keeps the suffix that distinguishes it from the aggregate. The four accepted
  folder spellings stay accepted.
- **`Dcb` in identifiers, `DCB` in prose.** Camel-case convention, not a doubled term.
- **Topic / channel / bus.** `EventTopic` and `CommandTopic` are components, `*Channel` is the
  transport abstraction they are built on, `LocalBus` is the in-process implementation of a
  channel. Three layers, three words.
- **`type state` means the decision model in a decision module and the stored row in a
  queryable spec.** Both are "the state this component keeps"; the glossary's *Decision model*
  entry names the first. Adding a *Row* entry beside it would close the gap without a rename.
- **`@retired` over `Archived`, `Deactivated`, `Discontinued`.** The annotation is the
  framework's one word; the constructors are the domain's. That is the design.
- **`@lifecycle` field, plugin lifecycle, `LifecycleModel`.** Three senses of one word, each
  qualified where it appears (`lifecycleField`, `plugin/lifecycle/`, `check:lifecycle`).
- **`status` on the platform's Plugins read model** is kept on purpose for wire stability and
  says so in its comment.
- **Caller / principal / identity.** *Caller* is the word (about 470 uses, `module Caller` in
  GWT); *principal* appears in prose where the sentence is about authorization in general. Not
  worth a sweep.
- **`capabilityNeeds` on a slice, `requiredCapabilities` on a plugin structure.** Different
  levels, and the structure's name follows the other `required*` fields beside it.
- **Four names for one plugin** (`plugin.json` name, the `<Name>Plugin` namespace, the npm
  package, the `<Name>Spec` contract package). Each is a different artifact's handle, and the
  naming rule in [app-developer.md](../../.claude/rules/app-developer.md) already ties them.
- **"app", "application", "bounded context" in prose** for a plugin or a platform. Explanatory
  prose, not framework terms; the glossary's *Plugin* and *Platform* entries are what they
  resolve to.

---

## 6. Spelling: behaviour and behavior

The prose in this repo leans British for words that are never identifiers and American for
words that are:

| Word | British | American |
|---|---|---|
| honour / honor | 37 | 6 |
| favour / favor | 22 | 5 |
| colour / color | 8 | 13 (`color` is a CSS property and a diagram-language keyword) |
| behaviour / behavior | 334 | 460 (`behavior` is the identifier) |

Nobody decided this; the identifiers pull toward American and the prose drifted toward British
one word at a time. Recommendation: **American spelling throughout**, prose and identifiers
alike. The identifiers are American already and cannot change (they bind to JavaScript and CSS
names), so American is the one choice where a doc never switches spelling between a sentence and
the code it describes, and it is the default of the ecosystems the framework sits in (ReScript,
Node, AWS, GraphQL). The sweep is larger than the other way round (about 400 British word hits
against 25 American ones to fix), but it is a docs-only find-and-replace over a short list of
words (*behaviour, honour, favour, colour, recognise, organise, licence, catalogue, modelling*),
and a small `check:spelling` grep over `docs/` and `packages/doc` keeps it from drifting back,
run by hand before a docs commit rather than in CI.

---

## 7. Order of work

1. The behavior → decision rename ([§3.6](#36-recommendation)), as one commit plus the PPX
   republish, with aliases.
2. The glossary entries for *Chapter* and *Section* ([§4.4](#44-recommendation)), small enough to
   ride on the same commit.
3. The renames marked *rename* in [§5](#5-other-doubled-terms), each in its own commit, in the
   order the table gives.
4. The spelling pass ([§6](#6-spelling-behaviour-and-behavior)), docs only, after the renames so
   the former term is not re-spelled first.
5. Removal of the aliases after one release window.

---

## 8. Decisions

| Id | Question | Recommendation |
|---|---|---|
| D1 | Rename *behavior* to *decision*? | Yes, suffix `_Decision`, attribute `@@reventless.decision`, module `Decision.T`, DSL `Decision_GWT`, with aliases for one window ([§3.6](#36-recommendation)). |
| D2 | *Decider* or *decision* as the suffix? | *Decision*; *decider* is named in the glossary as the pattern ([§3.5](#35-alternatives)). |
| D3 | *Chapter* or *section*? | *Chapter* everywhere a framework concept is named; *section* stays for list-view groups and document parts ([§4.4](#44-recommendation)). |
| D4 | Prose spelling? | American throughout, matching the identifiers ([§6](#6-spelling-behaviour-and-behavior)). |
