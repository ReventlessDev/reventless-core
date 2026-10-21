# Framework vocabulary: one chapter per term

**Status:** Analysis, 2026-10-21 (first version 2026-10-18). Nothing renamed yet. The open
decisions are listed in [§15](#15-decisions).

**Relates to:** [event-terminology-disambiguation.md](event-terminology-disambiguation.md)
(the earlier pass over "event" and "handler"),
[mapping-harmonization.md](mapping-harmonization.md) (the mapping body files),
[docs/plans/done/deployed-chapter-grouping.md](../plans/done/deployed-chapter-grouping.md)
(how the chapter became a deployed datum),
[docs/guides/terminology-guide.md](../guides/terminology-guide.md) (resource roles),
[.claude/rules/app-developer.md](../../.claude/rules/app-developer.md) (the file-naming table).

---

## In plain words

A framework is learned through its words. When one thing has two names, or one name means two
things, every reader pays a small toll each time, and the tools and docs built on the framework
have to pick a side. This analysis takes the framework's vocabulary one term at a time. Each
chapter says what the term names today, which other words could name it, what each choice would
cost and buy, and ends with a recommendation.

The terms, and the short answers:

| Chapter | Term today | Question | Answer |
|---|---|---|---|
| [§3](#3-behavior-or-decision) | behavior | call the write-side logic module the *decision*? | yes, as a hard rename with loud refusals and a codemod, no aliases |
| [§4](#4-chapter-or-section) | chapter | say *section* for a plugin's grouping band? | no, keep *chapter*; *section* is taken |
| [§5](#5-plugin-or-system) | plugin | call the deployable unit a *system*? | no, keep *plugin*; gloss it where plain words are needed |
| [§6](#6-view-queryable-or-read-side) | queryable, read side, view | one umbrella word for ReadModel and StateViewSlice? | *view* in words, *read side* in the code; what the UI draws is a *page* |
| [§7](#7-id-or-key-for-a-views-row-key) | `Key` / `Id` | one name for a view's row key? | yes, `Id` |
| [§8](#8-error-rejection-and-refusal) | error, rejected, refused | the words for a command that does not go through? | keep *error* for the declared reason; `thenRefused` becomes `thenForbidden`; a client should be told the cause |
| [§9](#9-event-handler-or-invocation-handler) | `eventHandler` | the runtime's handler of platform payloads? | `invocationHandler`, as proposed before |
| [§10](#10-multi-source-or-mixed-source) | mixed-source | the docs' word for a view fed by several sources? | *multi-source*, the code's word |
| [§11](#11-terms-that-need-a-definition-not-a-rename) | delegate, port, piece, … | undefined or stray words | glossary entries and doc edits |
| [§13](#13-spelling) | behaviour / behavior | which spelling? | American throughout |

Most of what the sweep found beyond these is deliberate layering, listed in
[§12](#12-deliberate-layering-leave-alone) so nobody re-opens it.

---

## 1. Scope and method

Counts come from a search over `reventless/*/src`, `examples/`, `traits/`,
`packages/reventless-ppx/src`, `packages/doc`, and `docs/`, excluding `node_modules`, `lib`, and
compiled `.res.mjs` files. They are rough and meant to show weight, not to be exact. Each
chapter follows the same shape: what the term names today, the alternatives, pros and cons, and
a recommendation. A term that only needs a definition gets a row in [§11](#11-terms-that-need-a-definition-not-a-rename)
instead of a chapter.

Two rules shaped the recommendations:

- **A word that is already a deployed datum costs more than a word in source.** `chapter` and
  `plugin` travel in the platform's read models and APIs; `behavior` does not.
- **A word that is specific beats a word that is common.** A common word (*section*, *system*,
  *context*) is already in use for something else nearby, and the reader has to disambiguate.

---

## 2. How the pieces are named today

```
Platform                         one deployment, assembles plugins
└── Plugin  (CatalogPlugin)      the deployable unit, registered and versioned by the platform
    └── Chapter  (src/Product/)  a grouping band inside the plugin
        └── Kind folder  (StateChange/, StateView/, Aggregate/, …)
            ├── Product.res            Spec: the types (command, event, error, state)
            └── Product_Behavior.res   the logic: state, initialState, evolve, decide
```

A write-side component is a spec file plus a logic file in one kind folder. Both aggregates and
DCB state-change slices implement the same module type,
[`Behavior.T`](../../reventless/spec/src/types/Behavior.res): a `state`, an `initialState`, an
`evolve` that folds one event into the state, and a `decide` that takes the state and a command
and answers with events or an error. The read-side body files follow the same `<Spec>_<Word>`
pattern with a word for what the file holds: `_Projection`, `_Projections`, `_Translation`,
`_Automation`, `_Mappings`
([`ComponentKind.bodySuffixes`](../../reventless/spec/src/components/ComponentKind.res)).

Of the 48 behavior files in this repo, 37 sit in `StateChange/` folders, 7 in `Aggregate/`, and
the rest are the framework's own (the platform's plugin aggregate
[`PluginBehavior.res`](../../reventless/core/src/plugin/lifecycle/PluginBehavior.res), the UI
fragment registry slice, and test fixtures).

---

## 3. Behavior or decision

### 3.1 What "behavior" names today

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

What already says *decision*:

- The function is `decide`. Its sibling helpers are `decideActing` (ownership refusal),
  `decideRetired`, `decideRelease`. There are 121 `decide*` identifiers in `src`.
- The glossary defines a **decision model**: "the ephemeral state a write-side component builds by
  replaying the events relevant to one command, folding them with `evolve` from `initialState`".
  That *is* the behavior module's `state`, built by the behavior module's `evolve`. The log
  events are `DecisionModelCacheHit`, `DecisionModelCacheMiss`, `DecisionModelDeltaEventCount`.
- A DCB slice's read of the event log is the *decision query* and its tags the *decision read*
  ([`DcbTag.res`](../../reventless/spec/src/components/DcbTag.res)).
- The pattern the module type implements, `{initialState, evolve, decide}`, is known in the
  event-sourcing community as the **decider** pattern. Nothing in the repo uses that name.

What else *behavior* means here: ten docs pages have a "Runtime Behavior" heading about how a
component acts at run time, the AWS stack has `orderedCacheBehaviors` (CloudFront's word), and
comments say "the deployment's behaviour". The spelling is split too, 570 *behaviour* against
580 *behavior* ([§13](#13-spelling)).

### 3.2 Alternatives

| Option | What it would read like | Verdict |
|---|---|---|
| **Decision**: `_Decision.res`, `@@reventless.decision`, `Decision.T`, `Decision_GWT` | "the AddProduct decision" | Recommended. A noun for what the file holds, like `_Projection` and `_Translation`; lines up with *decision model* and *decision query*. |
| **Decider**: `_Decider.res`, `Decider.T` | "the AddProduct decider" | Names the pattern exactly, but it would be the only agent noun among the body suffixes (`_Projection`, not `_Projector`). Name the pattern in the glossary, do not use it as the suffix. |
| **Keep Behavior** | as today | Costs nothing now and keeps paying the three-words toll (behavior, decision model, decide). Defensible only if the toll is judged smaller than one breaking release for every consumer. |
| **Logic** or **Handler**: `_Logic.res`, `_Handler.res` | "the AddProduct handler" | *Handler* is already the runtime's word for a dispatch entry ([§9](#9-event-handler-or-invocation-handler)); *logic* says nothing a reader can act on. |
| Rename the `StateChange/` folder to `Decision/` as well | `Decision/AddProduct.res` | No. *State Change*, *State View*, *Automation* and *Translation* are the established slice names of the modeling method the framework follows, and the folder word names the kind, not the file. |
| Rename `evolve` to `apply` or `fold` | | No. `evolve` is the decider pattern's own word and is consistent across aggregate and slice. |

### 3.3 Pros and cons of the rename

**For**

- The name says what the file does. `decide` is the one function a reader opens the file for;
  `evolve` and `initialState` exist to feed it.
- One word instead of three. The decision module builds the decision model and decides.
- *Behavior* stops being overloaded with its plain-English meaning, and the spelling split loses
  its hardest case.
- Plain-language surfaces that describe a write-side slice as "something that gets decided" meet
  the framework's own word a step earlier.

**Against**

- It is the widest rename the repo has done. The comparable slice-folder rename
  (commit `a40055512`, 2026-09-07) touched 379 files. This one touches the PPX, the generator,
  the GWT package, the AWS runtime builders, every example and trait, the docs, and the
  published PPX binary.
- *Decision* also carries the plain-language meaning of a whole write-side slice (spec plus
  logic). After the rename, "the AddProduct decision" names the slice in conversation and
  `AddProduct_Decision.res` names its logic file. The two readings nest rather than conflict, but
  the docs must say so once.
- `@@reventless.behavior` is in every downstream application's source, so the rename is a
  breaking change for each of them, and the PPX must be republished in lockstep with the core
  packages (the drill in [ppx-republish-single-commit.md](../plans/done/ppx-republish-single-commit.md)).
  [§3.5](#35-a-hard-rename-with-loud-refusals-not-aliases) explains why this is handled with
  refusals rather than aliases.

### 3.4 Recommendation

Rename *behavior* to *decision* everywhere it names the write-side logic module, as one
coordinated change with no aliases. The old spellings are refused loudly, each with a message
that says what to change:

1. **Spec and core.** `Behavior.res` becomes `Decision.res` with `module type T` unchanged in
   shape. No `module Behavior = Decision` alias: a reference to `Reventless.Behavior` fails to
   compile and the compiler names the missing module. `ComponentKind.bodySuffixes` replaces
   `_Behavior` with `_Decision`.
2. **PPX.** `@@reventless.decision` is the new attribute. `@@reventless.behavior` is a compile
   error: "renamed to `@@reventless.decision`; rename the file to `<Spec>_Decision.res`", the way
   `@status` is refused naming `@lifecycle`. The GWT inference reads `Decision` as the kind word
   and `_Decision` as the filename hint, and refuses `Behavior_GWT` with the same kind of message.
   The sidecar's kind label becomes `"Decision"`. Republish the PPX with the core packages.
3. **Generator.** Pairs a spec with `_Decision.res`. A `_Behavior.res` beside a spec is an error
   naming the file and the new name, never a silent second component.
4. **GWT.** `Decision_GWT` replaces `Behavior_GWT`. No alias module.
5. **AWS runtime builders.** `behaviorPath` → `decisionPath`, the runtime JSON key
   `behaviorModule` → `decisionModule`. These are written and read by the same deploy, so no
   stored data changes and no migration is needed.
6. **Examples, traits, the platform's own files.** `git mv` every `_Behavior.res` and update its
   attribute. Run the golden checks in the same commit.
7. **A codemod for downstream applications.** A small script that renames every `_Behavior.res`
   to `_Decision.res`, swaps the attribute, and replaces `Behavior_GWT` and `Reventless.Behavior`
   references, so a consumer's bump is one command plus a build. Ship it with the release and
   name it in the refusal messages.
8. **Docs.** Glossary: replace *Behavior* with *Decision* and say it implements the decider
   pattern, with one line saying it was called *Behavior* before. Rename the "Runtime Behavior"
   headings to "At run time". Update the file-naming table in
   [app-developer.md](../../.claude/rules/app-developer.md). The commit is `feat!`.

### 3.5 A hard rename with loud refusals, not aliases

An alias keeps the old name compiling for a while, so consumers can move at their own pace. It
is not needed here:

- **Every known consumer moves on purpose.** Applications pin published core versions, so a
  hard rename reaches them only when they bump, and the bump can carry their rename. The
  packages are still prereleases, where breaking changes are expected.
- **Nothing persisted carries the word.** No committed golden, lifecycle model or schema
  mentions `Behavior`. The runtime's `behaviorModule` key is written and read by one deploy, and
  the GWT sidecars are regenerated on every build. No data needs a migration.
- **The old spelling fails loudly, never silently.** A refusal names the new spelling and the
  codemod; without it, the missing `open Spec` alone would stop the file compiling. Nobody can
  ship a plugin that quietly lost its decisions.
- **An alias tends to stay.** The slice-folder rename kept every old folder spelling accepted,
  and they are all still accepted. A removal step that depends on someone remembering it is one
  that rarely happens, and until it does every reader meets both names.

The case for aliases would be external users on published prerelease versions who cannot be
reached and cannot move in one step. If such users appear before the rename lands, add an alias
for `Behavior.T` and `Behavior_GWT` only, with a removal date in the release notes, and keep the
PPX and generator refusals as they are.

---

## 4. Chapter or section

### 4.1 What "chapter" names today

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

So *chapter* is not a label. It is a grouping the framework acts on, with ~100 files in this repo
using the word and no other word for it in code. The modeling method the framework follows also
calls this grouping a chapter. The gap on the framework's side: the docs glossary has no *Chapter*
entry.

*Section* is already used nearby for two things that are not chapters:

| Meaning | Where |
|---|---|
| A list view's row groups, keyed by the `@groupBy` field ("AutoUI sections the admin Plugins view by kind") | [`PluginsReadModelSpec.res`](../../reventless/core/src/plugin/lifecycle/PluginsReadModelSpec.res), [`StateAnnotations.res`](../../reventless/spec/src/components/StateAnnotations.res), the UI library's list and detail views |
| A part of a document (every `§` link in `docs/`, the SDL's `type Query` section, a JWT's payload section) | prose everywhere |

Authoring surfaces built on the framework add a third: the top-level lists of an app's definition
file are its *sections*, and on the same screens a chapter is labelled "a section of *System*".

### 4.2 Alternatives

| Option | Verdict |
|---|---|
| **Keep chapter** everywhere, including plain-language surfaces | Recommended. Specific, established by the modeling method, already a deployed datum. |
| **Section** everywhere | Collides with the `@groupBy` row sections in every list view and with document sections, and would rename a deployed field for no gain in meaning. |
| **Area**, **Feature area**, **Group** | Common words with the same problem as *section*; *group* is also Cognito's word for a role's backing group. |
| **Module** | Collides with ReScript modules (2,700 hits). |
| **Context** | The DDD word for a plugin's level, not a chapter's ([§5](#5-plugin-or-system)). |

### 4.3 Pros and cons

**For chapter everywhere**

- Zero code changes here; the work is on surfaces that chose *section* as a gloss.
- *Chapter* has one meaning in the framework and one in the modeling method, and they agree.
  *Section* has at least three.
- Developers, the docs, the generated map, and the deployed manifest all say *chapter*. A person
  who learned *section* in a plain-language surface and then opens the source, the docs, or a
  pull request has to translate.
- Plain-language surfaces already gloss other framework words instead of replacing them (a
  StateChange slice is "something that gets decided"). The same device, "a chapter: a part of
  *System*", keeps the word and explains it.

**For section in plain-language surfaces**

- *Chapter* is a book metaphor and *section* a document metaphor; neither is obviously
  friendlier. The case made for *section* was that a components tree already used it, not that
  it reads better.
- An author who never sees a folder only needs *some* grouping word, until they meet the
  framework's word elsewhere.

### 4.4 Recommendation

Use *chapter* everywhere a framework concept is named, and reserve *section* for the two things
it already means: a list view's row groups and a part of a document. In this repo:

1. Add a glossary entry **Chapter**: the first non-kind folder under `src/`, carried as `chapter`
   on every component definition, used by the UI to group components and by the DCB partition
   inference to break ties.
2. Keep the "section" wording for `@groupBy` and say so in the glossary entry, so the two words
   are defined against each other.

Surfaces outside this repo that gloss the word should gloss it as they gloss the other kinds,
"a chapter, a part of *System*", rather than substituting *section*.

---

## 5. Plugin or system

### 5.1 What "plugin" names today

A plugin is the deployable unit: a set of components with their infrastructure, released and
versioned on its own, talking to other plugins only through extension points and extensions.
The word is everywhere, and much of it is on the wire:

| Surface | Spelling |
|---|---|
| The ReScript namespace and the composition root | `CatalogPlugin`, `<Namespace>.Plugin.Make(Platform)`, `src/plugin.json` |
| The framework component | [`Plugin.res`](../../reventless/core/src/plugin/component/Plugin.res), `Plugin_Builder`, `Plugin_Structure`, `pluginStructure`, `pluginDefinition`; 71 distinct `plugin*` / `Plugin_*` identifiers in spec and core, ~2,200 word hits |
| The platform's own bookkeeping | the **Plugin aggregate** and **Plugins read model** in [`plugin/lifecycle/`](../../reventless/core/src/plugin/lifecycle/), with statuses `Connected`, `Disconnected`, `Inactive`, `Retired`; the admin API that lists plugins and their structures |
| Contract packages | `<Name>Spec` namespaces for what a plugin exposes |
| Docs | glossary *Plugin* and *Platform*, [plugin-system.md](../../packages/doc/docs-app/plugin-system.md), [platform-and-plugin-guide.md](../../packages/doc/docs-app/platform-and-plugin-guide.md) |

*System* appears in the framework only as `externalSystem` (a foreign system a translation slice
talks to) and `systemCallable` (the platform calling its own API as a system principal, not a
person). In prose, "the system" means the whole deployment. Plain-language surfaces built on the
framework call a plugin "a separate system", with the consequence spelled out ("systems cannot
read each other's data directly").

One plugin has four handles, each for a different artifact: the `plugin.json` name (`Catalog`),
the namespace (`CatalogPlugin`), the npm package, and the contract package (`CatalogSpec`). That
is not a doubled term; the naming rule in [app-developer.md](../../.claude/rules/app-developer.md)
ties them.

### 5.2 Alternatives

| Option | What it says | Verdict |
|---|---|---|
| **Keep plugin** | a part that plugs into a platform, registered, versioned, connected, retired | Recommended. Accurate (the lifecycle verbs are a plugin's), established in the framework's own API, and the most expensive word in the repo to move. |
| **System** | a separate thing with its own model | The plain-language gloss, and a good one for a first-time author. As the framework's word it collides with `externalSystem` (a *foreign* system) and `systemCallable` (the platform acting as itself), and "the system" already means the whole deployment. In a platform of three plugins, "which system?" is the question *plugin* answers. |
| **Context**, **Bounded context** | DDD's word for exactly this: its own model, its own language, data not shared across the line | The most precise alternative, and the modeling method's import format uses `context` for a slice's home. But `context` is already `RequestContext` and the Lambda context (~480 hits), *bounded context* is two words nobody will type into an identifier, and it is abstract to a non-developer. Worth naming in the glossary as what a plugin *is*; not worth becoming the word. |
| **Module** | a unit of code | Collides with ReScript modules (2,700 hits). Fatal. |
| **Service** | a running thing with an API | Implies one process; a plugin is several Lambdas, tables and queues. `meta.service` is already a dispatch key on the envelope. |
| **App**, **Application** | the thing a business runs | That is the platform, or the whole deployment. A plugin is a part of it. |
| **Subsystem** | a part of a system that can be released on its own | Honest and collision-free, but clumsy, not a term of any method the framework follows, and still leaves "system" meaning the whole. |
| **Domain** | the business area | Too broad: *domain event*, *domain trait*, *domain model* all use it for something else. |

### 5.3 Pros and cons of keeping plugin

**For**

- It is right. A plugin registers with the platform, has versions, connects, disconnects, is
  retired. Those are the verbs the platform's Plugin aggregate implements, and they read
  naturally with *plugin* and oddly with *system* ("retire a system").
- It is a deployed datum in more places than any other word: the Plugins read model, the admin
  API, every `pluginStructure`, the manifest the UI reads. Renaming it is a wire change for every
  deployment and every downstream application's namespaces.
- Readers from the wider ecosystem know what a plugin is: a unit that extends a host and can be
  added and removed. That is the right picture.

**Against**

- To a business reader, *plugin* can sound optional, an add-on rather than the whole catalog or
  the whole ordering. The plain-language gloss exists because of this.
- The word does three jobs: the kind of thing (a plugin), the namespace suffix (`CatalogPlugin`),
  and the platform's own Plugin aggregate that tracks the others. Only the glossary tells them
  apart.

### 5.4 Recommendation

Keep *plugin* as the framework's word and do not rename anything. Two small docs changes:

1. Extend the glossary's *Plugin* entry with one sentence saying what it is in DDD terms (a
   bounded context: its own model, its own event log, no shared tables) and that plain-language
   surfaces may call it "a separate system".
2. Note in the same entry that the platform's own *Plugin aggregate* is the registry of plugins,
   so the capitalised name is not confused with the kind.

If the word is ever revisited, *context* is the only alternative with more precision than
*plugin*, and it does not pay for the wire change.

---

## 6. View, queryable or read side

### 6.1 What the read side is called today

The framework has two read-side kinds, `ReadModel` (aggregate style) and `StateViewSlice` (DCB
style). Each kind keeps its own name, and that is deliberate
([§12](#12-deliberate-layering-leave-alone)). The trouble is the word for *both*, which has four
names:

| Where | Name | Its write-side partner |
|---|---|---|
| ReScript types in the plugin structure | `queryableDef`, with `isPublicQueryable`, `internalQueryables`, `encodeQueryableDef` (about 70 hits) | `writableDef` |
| The platform API schema | `Platform_ReadSideDef`, on `readModels`, `stateViewSlices` and `internalQueryables` | `Platform_WriteSideDef`, and the field `linkedWriteSide` |
| The AWS component-definitions handler | `readSideCollections`, `readSideHeal` | — |
| Prose, comments, the docs, and many identifiers | *view*: "no view lists it", "the view's rows", `linkedViews`, `identityViews`, about 220 mentions in the app docs | — |

The glossary has no entry for any of them, and the two entries it does have are circular:

- [*Projection*](../../packages/doc/docs-app/glossary.md#projection): "a mapping from one event
  type to a read model state update. A read model composes several of them."
- [*ReadModel*](../../packages/doc/docs-app/glossary.md#readmodel): "a query-side projection of
  events into a queryable store."

So a projection is part of a read model, and a read model is a projection. A third entry,
[*StateViewSlice*](../../packages/doc/docs-app/glossary.md#stateviewslice), says its view is
"used for queries or validation". No mechanism in the spec, the core component, or the component
docs uses a state view for validation: a DCB state-change slice validates by reading its own
consumed events. The "or validation" is a leftover.

*View* is also the word for what the generated UI draws from a view: "list view" (about 36
mentions in the docs), "detail view" (about 15), "board". So the docs can end up writing "the
list view of the Products view". The docs say "list page" and "detail page" only about ten
times, and plain-language surfaces built on the framework already call it a "generated page".

Other uses of *view* are external and already qualified: DynamoDB's `streamViewType`, CloudFront's
viewer settings, and the host configuration's `viewModes`, which chooses whether a page shows
its rows as a list or a map.

### 6.2 Alternatives for the umbrella word

| Option | Verdict |
|---|---|
| **View** | Recommended as the word in prose and the glossary. It is already the prose winner, it is the modeling method's word (the view slice, the green box), and it pairs with *decision* on the write side. Its one collision, the UI's "list view", is resolved by calling what the UI draws a page ([§6.4](#64-recommendation)). |
| **Read side** | Recommended as the word in identifiers. It is the CQRS term every developer knows, the platform API already uses it with its write-side partner, and it names the half of the architecture a definition belongs to, which is what a type name needs. As a word for one component it reads badly ("a read side lists products"), so it is not the prose word. |
| **Queryable** | The current ReScript name. Precise, but an adjective used as a noun, nobody says it, and it pairs with *writable*, which describes nothing a reader knows. |
| **Read model** | The aggregate-style kind's own name. Using it for both kinds would make every "ReadModel" ambiguous between the kind and the umbrella, which is the problem this chapter is solving. |
| **Projection** | The function inside a view, not the view. Using it for the component is what made the glossary circular. |
| **Query** | The GraphQL operation a view answers, not the view. |

### 6.3 Pros and cons

**For view in words and read side in code**

- One word in prose that already wins, matches the modeling method, and pairs with *decision*:
  decisions on the write side, views on the read side.
- One name in code that already exists on the wire. Aligning the ReScript types to the API
  schema changes no field and no type a client selects, so no consumer's query breaks.
- *Projection* gets one meaning back: the fold from an event into a view's row, the same in both
  styles.
- Calling the UI's drawings *pages* removes the only real collision and matches the word
  plain-language surfaces use already.

**Against**

- Two words for one idea, *view* in prose and *read side* in code. The split is defensible
  because each is the natural word in its place, and the glossary says so in one line, but it
  is a split.
- *Read side* is a CQRS term a non-developer will not know. That is acceptable because it only
  appears in identifiers.
- The type rename reaches the other packages that read the plugin structure, about ten files
  outside the framework packages, on their next bump.
- *Page* is a new docs word for something the docs have called a view for a long time. About 50
  mentions move.

### 6.4 Recommendation

1. **Glossary.** Add *View*: "a read-side component, a ReadModel or a StateViewSlice; in the code
   and the platform API its definition is a *read-side def*". Rewrite *Projection* as "the
   function that folds one event into a view's row, `event × state → state`, in both styles; a
   ReadModel holds one per source event, a StateViewSlice one in total". Rewrite *ReadModel* as
   "the aggregate-style view" without calling it a projection. Drop "or validation" from
   *StateViewSlice*.
2. **Code.** Rename `queryableDef` to `readSideDef` and `writableDef` to `writeSideDef`, with
   `isPublicQueryable` and `encodeQueryableDef` following. This is source only, a hard rename
   like [§3.5](#35-a-hard-rename-with-loud-refusals-not-aliases): the compiler names every place.
   Leave the API schema's `Platform_ReadSideDef` and `Platform_WriteSideDef` as they are, since
   they already have the right names, and leave the wire field `internalQueryables` alone: renaming
   it is a breaking change for a field name alone.
3. **Pages, not views, for what the UI draws.** In the docs, the list view, detail view and board
   of a view become its *list page*, *detail page* and *board page*, and "a view's pages" is the
   collective. Leave identifiers alone, including `viewModes`: it names how a page shows its
   rows, and it is a host configuration key on the wire.
4. **Leave the components alone.** `ReadModel`, `StateViewSlice` and the `StateView/` folder keep
   their names.

---

## 7. Id or Key for a view's row key

### 7.1 Today

A read model's row key is `module Id: Id.T`
([`ReadModel.res`](../../reventless/spec/src/components/ReadModel.res) line 174). A state view's
row key, the same role, is `module Key: Id.T`
([`StateViewSlice.res`](../../reventless/spec/src/components/StateViewSlice.res) line 60), and
the PPX injects `module Key = Reventless.Id.StringPure` into a `StateView/` file. The likely
reason for the difference: `@@reventless.spec` injects a `module Id` into every spec file for the
*component's* identity, and the state view needed a second name for the *row's*.

### 7.2 What the collision check found

`@@reventless.spec` injects `module Id = Reventless.Id.String` into every spec file that does not
declare one ([`ReventlessPpx.ml`](../../packages/reventless-ppx/src/ppx/ReventlessPpx.ml) line
263). A `StateView/` file therefore holds **both** modules today: the generic `Id`, then the row
key `Key` the same pass injects at line 897. A compiled state view spec exports both. So a
straight rename of `Key` to `Id` would collide.

The generic `Id` on a state view is dead weight, though. Nothing reads it:
[`StateViewSlice.Spec`](../../reventless/spec/src/components/StateViewSlice.res) does not
require it, and the core builder and callback, the GWT projection DSL and both runtimes reach the
row key only through `Spec.Key`. In a read model the same injected `Id` *is* the row key,
which is why the read model needs no second name.

Five views in the examples declare their row key by hand, `module Key = OrderId` and the like.

### 7.3 Alternatives and verdict

| Option | Verdict |
|---|---|
| **`Id` on both, and the PPX stops injecting the generic `Id` into `StateView/` files** | Recommended. A state view then has one identity module, the row key, under the same name as a read model's. The PPX injects `module Id = Reventless.Id.StringPure` where it injects `Key` today, and a hand-written `module Id = OrderId` suppresses it, as `Key` does now. |
| **`Key` on both** | Works without touching the injection, but renames the read model's `Id`, which every read model spec and its builders use, and leaves the dead generic `Id` on every state view. |
| Leave as is | Every doc that explains the row key has to say "Id, or Key on a state view". |

No alias: a hand-written `module Key` in a `StateView/` file is refused with a message naming
`module Id`, as in [§3.5](#35-a-hard-rename-with-loud-refusals-not-aliases). The build that
drops the generic injection is the proof that nothing read it.

---

## 8. Error, rejection and refusal

### 8.1 Today

When a command does not go through, the framework uses three words, and two of them mean more
than one thing.

**The domain's no.** A decision declines a command by returning one of the reasons its spec
declares. The reason and the outcome have different words, and that layering is sound:

| Role | Word | Where |
|---|---|---|
| The declared reason | *error* | `@schema type error` in 55 specs, `decide` returning ReScript's built-in `Error(CategoryNotFound)`, the test step `thenError` (222 uses), the wire's `errorCode` |
| The outcome | *rejection* | the wire's `CommandRejected`, the handler's `DomainRejection` |

**Refused** means three things:

| Where | Meaning |
|---|---|
| [`CommandTopic_Helpers.res`](../../reventless/core/src/components/CommandTopic/CommandTopic_Helpers.res) line 32 | the umbrella over every no, `refusalCause = DomainRejection \| InfrastructureFailure \| AccessRefusal` |
| [`Behavior_GWT.res`](../../reventless/gwt/src/Behavior_GWT.res) line 278, `thenRefused` (63 uses) | access refusal only: the caller may not act. The PPX records it as sidecar kind `forbidden` |
| [`CheckLifecycleModel.res`](../../reventless/spec/src/lifecycle/CheckLifecycleModel.res) lines 598 and 649, `outcome = Refused` | a *domain* rejection, mapped from the sidecar's `"error"` kind |

On top of that, *refuse* is everyday prose here, about 100 times in the app docs and in the
conventions, for any check that says no: "refused at build time", "a deploy that declares one
the platform does not provide is refused". Plain-language surfaces built on the framework call a
declared error a *refusal*.

**One wire outcome for every no.** A client receives `CommandRejected {errorCode, errorDetail}`
for all three causes. The cause itself never leaves the platform. The helper's own comment says
the cause exists "so without this a consumer would read a broken event log as a business
rejection", but that protects only consumers inside the platform. A GraphQL client still reads a
failed append as a rejection, because its only clue is `errorCode`, and the platform's own codes
share that namespace with every spec's error variant names:

| `errorCode` the platform puts on `CommandRejected` | Cause |
|---|---|
| `Forbidden` | access refusal, before `decide` runs |
| `AppendFailed` | an event-log append the store failed, from an aggregate or a slice |
| `Conflict` | a slice's conflict retries exhausted, or any other failure of the handler |

(An inbound webhook's `Unsigned`, `InvalidBody` and `PublishFailed` are answered as HTTP statuses
401, 400 and 503, not as `CommandRejected`, so they do not clash.)

No example declares a clashing error today, but nothing stops a spec from declaring `| Conflict`,
and then a client cannot tell "retry later" from "the model said no".

### 8.2 Alternatives for the words

| Option | Verdict |
|---|---|
| **Keep *error* for the declared reason, add a glossary entry** | Recommended. `decide` returns `Error(...)`, the language's own result constructor, which cannot be renamed. A type called `rejection` that is built with `Error(...)` would read worse than today. |
| Rename `type error` to `type rejection` or `type reason` | No. It fights the language, touches every spec, every test and the wire's `errorCode`, and still leaves `Error(...)` in every `decide`. |
| **Rename `thenRefused` to `thenForbidden`** | Recommended. It matches the wire's `errorCode: "Forbidden"` and the sidecar kind `forbidden`, so the test step, the sidecar and the wire say the same word. *Refuse* is then free to stay plain English. |
| Make *refused* mean "the platform's no", as a rule for prose | No, which reverses this chapter's first version. *Refuse* is everyday prose for any check, and a plain-language *refusal* is a domain error, the opposite. A word used that widely cannot carry a narrow technical meaning. |
| **Rename the lifecycle harvest's `Refused` to `Rejected`** | Recommended. It names a domain rejection, which the wire and `DomainRejection` already call a rejection. |
| *Denied* for access | No. `AccessDenied` is IAM's word for an infrastructure error here. |

`refusalCause` and `AccessRefusal` stay as they are: the umbrella is internal, and its arms
already say which no they are.

### 8.3 Alternatives for telling a client which no it got

| Option | Verdict |
|---|---|
| **Add `cause: DOMAIN \| ACCESS \| INFRASTRUCTURE` to `CommandRejected`** | Recommended. Additive: an existing query keeps working, a client that selects the field can decide between showing the reason, asking the caller to sign in, and retrying. The platform already computes the cause. |
| **Reserve the platform's codes** | Recommended with the field. The PPX refuses a spec error variant named like a platform code, so the `errorCode` namespace cannot clash even for a client that ignores `cause`. |
| A separate `CommandFailed` member of the result union for infrastructure failures | Cleaner in the long run, but breaking for every client that handles the union exhaustively. Worth it only if a second breaking change to the result shape is planned anyway. |
| Prefix the platform's codes (`Platform.Conflict`) | Breaking for every client that matches `Forbidden` today, and it solves the clash without telling the client the cause. |
| Leave | A client keeps reading infrastructure failures as business rejections. |

### 8.4 Recommendation

1. **Glossary.** Add *Error*: "in a spec, a named reason a decision rejects a command. It is not
   a failure: returning one is the model working. The outcome a client sees is a *rejection*."
   Add *Rejection* beside it, and say that a plain-language *refusal* is a declared error.
2. **GWT.** Rename `thenRefused` to `thenForbidden`, as a hard rename with a refusal message
   like [§3.5](#35-a-hard-rename-with-loud-refusals-not-aliases). It can ride on the
   behavior-to-decision rename, which touches the same test files and the same DSL.
3. **Lifecycle harvest.** Rename `outcome = Refused` to `Rejected`.
4. **The client cause.** Add the `cause` field and the reserved-code check. This changes behavior
   and the GraphQL contract goldens, so it goes into its own plan rather than into this rename
   work.
5. **Prose.** *Refuse* stays plain English for any check that says no.

---

## 9. Event handler or invocation handler

### 9.1 Today

[`Runtime.res`](../../reventless/core/src/adapter/Runtime/Runtime.res) line 1 still declares
`type eventHandler<'event, 'context, 'result>` for the function a Lambda or the local runtime
invokes with its *payload*, which is not a domain event.
[event-terminology-disambiguation.md](event-terminology-disambiguation.md) proposed
`invocationHandler<'payload, …>` for it and the dispatch dictionaries renamed to `*Dispatchers`.
None of that was applied.

### 9.2 Alternatives and verdict

| Option | Verdict |
|---|---|
| **`invocationHandler`, `'payload`**, as proposed | Recommended. Internal to the runtime layer; no application code names it. |
| `triggerHandler` | Equivalent; *invocation* is the cloud providers' own word. |
| Leave | *Event* keeps meaning two things in the one layer where the difference matters most. |

---

## 10. Multi-source or mixed-source

### 10.1 Today

The GWT DSL and the code say *multi-source*
([`MultiSourceProjection_GWT.res`](../../reventless/gwt/src/MultiSourceProjection_GWT.res)).
The docs say *mixed-source* in two page names and their prose
(`mixed-source-readmodel.md` and `mixed-source-automationslice.md`, since renamed to
[`multi-source-readmodel.md`](../../packages/doc/docs-app/multi-source-readmodel.md) and
[`multi-source-automationslice.md`](../../packages/doc/docs-app/multi-source-automationslice.md)),
about 20 files each way.

### 10.2 Verdict

*Multi-source*: rename the two pages and their prose. Moving the identifier instead would be a
breaking change for every test that names it, and *multi* says "several" where *mixed* hints at "of different kinds", which
is not the point.

---

## 11. Terms that need a definition, not a rename

| Term | Problem | Where | Fix |
|---|---|---|---|
| **Delegate** | the local event source in an extension-point mapping, the local command target in an extension, and the GWT kind for the boundary (`Delegate_GWT`); none is in the glossary | [`extensionpoint.md`](../../packages/doc/docs-app/components/extensionpoint.md), [`plugin-system.md`](../../packages/doc/docs-app/plugin-system.md), [`Delegate_GWT.res`](../../reventless/gwt/src/Delegate_GWT.res) | One glossary entry: "the local component an extension point or extension stands in for; on the publishing side its events, on the consuming side its commands". The code is consistent; the docs never say it once. |
| **Port** | used for an extension point's translation table in two pages and the PPX, defined nowhere | [`extensionpoint.md`](../../packages/doc/docs-app/components/extensionpoint.md), [`extension.md`](../../packages/doc/docs-app/components/extension.md), [`TranslationTable.ml`](../../packages/reventless-ppx/src/ppx/TranslationTable.ml) | Replace the three uses with the component's name; cheaper than adding a word. |
| **Piece** vs **role** | the terminology guide says "role, not piece"; the module it governs says *piece* in its own comments | [`terminology-guide.md`](../guides/terminology-guide.md) line 98, [`ResourceAttribution.res`](../../reventless/core/src/ResourceAttribution.res) lines 12, 43, 108 | Replace in the comments; no identifier carries it. |
| **`apply`**, **`handle`** in doc examples | where the framework's functions are `evolve` and `decide` | [`application-development-layers.md`](../../packages/doc/docs-framework/application-development-layers.md) lines 111 and 699, [`commandgenerator.md`](../../packages/doc/docs-framework/runtime-components/commandgenerator.md) line 86, [`rescript-syntax.md`](../../packages/doc/docs-app/rescript-syntax.md) line 119 | Four edits, with the rename in [§3.4](#34-recommendation), which touches the same pages. |
| **Body suffix vs attribute** | `_Projections` pairs with `@@reventless.mappings`, `_Projection` with `@@reventless.projection`, `_Mappings` with `@@reventless.mappings` | [`Vocabulary.ml`](../../packages/reventless-ppx/src/ppx/Vocabulary.ml) lines 67 and 70 | Leave the names: the attribute names the shape (a list of per-source mappings, used by two file kinds) and the suffix names the output. Add the attribute column to the file-naming table so the pairing is visible. |
| **`type state`** | the decision model in a decision module; the stored row in a queryable spec | [`StateChangeSlice.res`](../../reventless/spec/src/components/StateChangeSlice.res), [`StateViewSlice.res`](../../reventless/spec/src/components/StateViewSlice.res) | Add a glossary entry *Row* beside *Decision model*. |
| **Refusal** (plain word) | a declared error in plain-language surfaces | [§8](#8-error-rejection-and-refusal) | Say so in the glossary's *Error* and *Rejection* entries. |
| **GWT test suffixes** | framework tests are `*GwtTest.res`, example tests `*_GWT.res`; the PPX accepts `_GWT`, `GwtTest` and `Gwt` | [`GwtInference.ml`](../../packages/reventless-ppx/src/ppx/GwtInference.ml), [`reventless/gwt/tests/`](../../reventless/gwt/tests/) | Leave. The framework's own tests are not the form the docs teach, and the tolerance is cheap. |

---

## 12. Deliberate layering, leave alone

Named here so the next sweep does not re-find them.

- **Aggregate style and DCB style run parallel vocabularies** on purpose: `ReadModel` /
  `StateViewSlice`, `_Projections` / `_Projection`, `EventMapping` / `AutomationSlice`, and the
  shared umbrella over both, today `queryableDef` / `writableDef` and after [§6.4](#64-recommendation)
  `readSideDef` / `writeSideDef`.
- **`StateChangeSlice` on types, `StateChange/` on folders.** Decided in
  [`ComponentKind.res`](../../reventless/spec/src/components/ComponentKind.res): the folder names
  the kind, the type keeps the suffix that distinguishes it from the aggregate. The four accepted
  folder spellings stay accepted.
- **`Dcb` in identifiers, `DCB` in prose.** Camel-case convention, not a doubled term.
- **Topic / channel / bus.** `EventTopic` and `CommandTopic` are components, `*Channel` is the
  transport abstraction they are built on, `LocalBus` is the in-process implementation of a
  channel. Three layers, three words.
- **`@retired` over `Archived`, `Deactivated`, `Discontinued`.** The annotation is the
  framework's one word; the constructors are the domain's.
- **`@lifecycle` field, plugin lifecycle, `LifecycleModel`.** Three senses of one word, each
  qualified where it appears (`lifecycleField`, `plugin/lifecycle/`, `check:lifecycle`).
- **`status` on the platform's Plugins read model** is kept on purpose for wire stability and
  says so in its comment.
- **Caller / principal / identity.** *Caller* is the word (about 470 uses, `module Caller` in
  GWT); *principal* appears in prose where the sentence is about authorization in general.
- **`capabilityNeeds` on a slice, `requiredCapabilities` on a plugin structure.** Different
  levels, and the structure's name follows the other `required*` fields beside it.
- **"app", "application", "bounded context" in prose** for a plugin or a platform. Explanatory
  prose; the glossary's *Plugin* and *Platform* entries are what they resolve to
  ([§5](#5-plugin-or-system)).

---

## 13. Spelling

The prose in this repo leans British for words that are never identifiers and American for
words that are:

| Word | British | American |
|---|---|---|
| honour / honor | 37 | 6 |
| favour / favor | 22 | 5 |
| recognise / recognize | 18 | 4 |
| modelling / modeling | 30 | 37 |
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

## 14. Order of work

1. The behavior → decision rename ([§3.4](#34-recommendation)), as one commit plus the PPX
   republish, the refusals and the codemod. The doc-example edits of [§11](#11-terms-that-need-a-definition-not-a-rename)
   and the `thenRefused` → `thenForbidden` rename ([§8.4](#84-recommendation)) ride on it, since
   they touch the same pages, test files and DSL.
2. The glossary entries: *Chapter* and *Section* ([§4.4](#44-recommendation)), the *Plugin*
   extension ([§5.4](#54-recommendation)), *View* with the rewritten *Projection*, *ReadModel*
   and *StateViewSlice* ([§6.4](#64-recommendation)), *Error* and *Rejection* ([§8.4](#84-recommendation)), *Delegate*, *Row*
   ([§11](#11-terms-that-need-a-definition-not-a-rename)). Small enough for one docs commit.
3. The *page* wording for what the UI draws ([§6.4](#64-recommendation)), docs only, its own
   commit since it touches about 50 mentions.
4. The `queryableDef` → `readSideDef` rename ([§6.4](#64-recommendation)), source only, its own
   commit.
5. The row key ([§7](#7-id-or-key-for-a-views-row-key)), its own commit, with a PPX republish.
6. The lifecycle harvest's `Refused` → `Rejected` ([§8](#8-error-rejection-and-refusal)) and the
   runtime's `invocationHandler` ([§9](#9-event-handler-or-invocation-handler)), one commit each.
   The client cause on `CommandRejected` ([§8.3](#83-alternatives-for-telling-a-client-which-no-it-got))
   is not part of this list: it changes behavior and gets a plan of its own.
7. The *multi-source* page rename ([§10](#10-multi-source-or-mixed-source)) and the *port* /
   *piece* edits, one docs commit.
8. The spelling pass ([§13](#13-spelling)), docs only, after the renames so the former term is
   not re-spelled first.

---

## 15. Decisions

| Id | Question | Recommendation |
|---|---|---|
| D1 | Rename *behavior* to *decision*? | Yes: suffix `_Decision`, attribute `@@reventless.decision`, module `Decision.T`, DSL `Decision_GWT`; the old spellings are refused with a message, a codemod ships with the release, no aliases ([§3.4](#34-recommendation), [§3.5](#35-a-hard-rename-with-loud-refusals-not-aliases)). |
| D2 | *Decider* or *decision* as the suffix? | *Decision*; *decider* is named in the glossary as the pattern ([§3.2](#32-alternatives)). |
| D3 | *Chapter* or *section*? | *Chapter* everywhere a framework concept is named; *section* stays for list-view groups and document parts ([§4.4](#44-recommendation)). |
| D4 | *Plugin* or *system*? | *Plugin*; glossary says it is a bounded context and that plain-language surfaces may gloss it as a separate system ([§5.4](#54-recommendation)). |
| D5 | `Id` or `Key` for a view's row key? | `Id` on both; the PPX stops injecting the unused generic `Id` into `StateView/` files and injects the row key as `Id` ([§7.3](#73-alternatives-and-verdict)). |
| D6 | Error, rejection and refusal? | Keep *error* for the declared reason, with a glossary entry; *rejection* is the outcome; `thenRefused` becomes `thenForbidden` and the lifecycle harvest's `Refused` becomes `Rejected`; *refuse* stays plain English ([§8.4](#84-recommendation)). |
| D11 | Tell a client which kind of no it got? | Yes: an additive `cause` field on `CommandRejected` and the platform's error codes reserved against spec error names, in a plan of its own ([§8.3](#83-alternatives-for-telling-a-client-which-no-it-got)). |
| D7 | Apply the earlier `invocationHandler` proposal? | Yes ([§9](#9-event-handler-or-invocation-handler)). |
| D8 | *Multi-source* or *mixed-source*? | *Multi-source*, in the docs ([§10](#10-multi-source-or-mixed-source)). |
| D9 | Prose spelling? | American throughout, matching the identifiers ([§13](#13-spelling)). |
| D10 | One umbrella word for ReadModel and StateViewSlice? | *View* in prose and the glossary, *read side* in identifiers (`readSideDef`, matching the API schema); what the UI draws from a view is a *page* ([§6.4](#64-recommendation)). |
