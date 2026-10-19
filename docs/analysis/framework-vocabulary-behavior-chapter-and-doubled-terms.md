# Framework vocabulary: one chapter per term

**Status:** Analysis, 2026-10-19 (first version 2026-10-18). Nothing renamed yet. The open
decisions are listed in [§14](#14-decisions).

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
| [§3](#3-behavior-or-decision) | behavior | call the write-side logic module the *decision*? | yes, with a compatibility window |
| [§4](#4-chapter-or-section) | chapter | say *section* for a plugin's grouping band? | no, keep *chapter*; *section* is taken |
| [§5](#5-plugin-or-system) | plugin | call the deployable unit a *system*? | no, keep *plugin*; gloss it where plain words are needed |
| [§6](#6-id-or-key-for-a-views-row-key) | `Key` / `Id` | one name for a view's row key? | yes, `Id` |
| [§7](#7-rejected-or-refused) | refused | what does *refused* mean? | the platform's no; *rejected* is the domain's no |
| [§8](#8-event-handler-or-invocation-handler) | `eventHandler` | the runtime's handler of platform payloads? | `invocationHandler`, as proposed before |
| [§9](#9-multi-source-or-mixed-source) | mixed-source | the docs' word for a view fed by several sources? | *multi-source*, the code's word |
| [§10](#10-terms-that-need-a-definition-not-a-rename) | delegate, port, piece, … | undefined or stray words | glossary entries and doc edits |
| [§12](#12-spelling) | behaviour / behavior | which spelling? | American throughout |

Most of what the sweep found beyond these is deliberate layering, listed in
[§11](#11-deliberate-layering-leave-alone) so nobody re-opens it.

---

## 1. Scope and method

Counts come from a search over `reventless/*/src`, `examples/`, `traits/`,
`packages/reventless-ppx/src`, `packages/doc`, and `docs/`, excluding `node_modules`, `lib`, and
compiled `.res.mjs` files. They are rough and meant to show weight, not to be exact. Each
chapter follows the same shape: what the term names today, the alternatives, pros and cons, and
a recommendation. A term that only needs a definition gets a row in [§10](#10-terms-that-need-a-definition-not-a-rename)
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
580 *behavior* ([§12](#12-spelling)).

### 3.2 Alternatives

| Option | What it would read like | Verdict |
|---|---|---|
| **Decision**: `_Decision.res`, `@@reventless.decision`, `Decision.T`, `Decision_GWT` | "the AddProduct decision" | Recommended. A noun for what the file holds, like `_Projection` and `_Translation`; lines up with *decision model* and *decision query*. |
| **Decider**: `_Decider.res`, `Decider.T` | "the AddProduct decider" | Names the pattern exactly, but it would be the only agent noun among the body suffixes (`_Projection`, not `_Projector`). Name the pattern in the glossary, do not use it as the suffix. |
| **Keep Behavior** | as today | Costs nothing now and keeps paying the three-words toll (behavior, decision model, decide). Defensible only if no other rename is planned, because the compatibility window is the expensive part and is best shared. |
| **Logic** or **Handler**: `_Logic.res`, `_Handler.res` | "the AddProduct handler" | *Handler* is already the runtime's word for a dispatch entry ([§8](#8-event-handler-or-invocation-handler)); *logic* says nothing a reader can act on. |
| Rename the `StateChange/` folder to `Decision/` as well | `Decision/AddProduct.res` | No. *State Change*, *State View*, *Automation* and *Translation* are the established slice names of the modelling method the framework follows, and the folder word names the kind, not the file. |
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
- `@@reventless.behavior` is in every downstream application's source. A window where both
  spellings compile is needed, and the PPX must be republished in lockstep with the core packages
  (the drill in [ppx-republish-single-commit.md](../plans/done/ppx-republish-single-commit.md)).

### 3.4 Recommendation

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
   attribute. Run the golden checks in the same commit.
7. **Docs.** Glossary: replace *Behavior* with *Decision* and say it implements the decider
   pattern; keep a one-line *Behavior (former name)* entry for a window. Rename the "Runtime
   Behavior" headings to "At run time". Update the file-naming table in
   [app-developer.md](../../.claude/rules/app-developer.md).
8. **Remove the aliases** after the window, in a `feat!` commit.

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
using the word and no other word for it in code. The modelling method the framework follows also
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
| **Keep chapter** everywhere, including plain-language surfaces | Recommended. Specific, established by the modelling method, already a deployed datum. |
| **Section** everywhere | Collides with the `@groupBy` row sections in every list view and with document sections, and would rename a deployed field for no gain in meaning. |
| **Area**, **Feature area**, **Group** | Common words with the same problem as *section*; *group* is also Cognito's word for a role's backing group. |
| **Module** | Collides with ReScript modules (2,700 hits). |
| **Context** | The DDD word for a plugin's level, not a chapter's ([§5](#5-plugin-or-system)). |

### 4.3 Pros and cons

**For chapter everywhere**

- Zero code changes here; the work is on surfaces that chose *section* as a gloss.
- *Chapter* has one meaning in the framework and one in the modelling method, and they agree.
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
| **Context**, **Bounded context** | DDD's word for exactly this: its own model, its own language, data not shared across the line | The most precise alternative, and the modelling method's import format uses `context` for a slice's home. But `context` is already `RequestContext` and the Lambda context (~480 hits), *bounded context* is two words nobody will type into an identifier, and it is abstract to a non-developer. Worth naming in the glossary as what a plugin *is*; not worth becoming the word. |
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

## 6. Id or Key for a view's row key

### 6.1 Today

A read model's row key is `module Id: Id.T`
([`ReadModel.res`](../../reventless/spec/src/components/ReadModel.res) line 174). A state view's
row key, the same role, is `module Key: Id.T`
([`StateViewSlice.res`](../../reventless/spec/src/components/StateViewSlice.res) line 60), and
the PPX injects `module Key = Reventless.Id.StringPure` into a `StateView/` file. The likely
reason for the difference: `@@reventless.spec` injects a `module Id` into every spec file for the
*component's* identity, and the state view needed a second name for the *row's*.

### 6.2 Alternatives and verdict

| Option | Verdict |
|---|---|
| **`Id` on both** | Recommended if the injected component `Id` does not collide; check this first. The read model's `Id` already lives with that injection, which suggests it does not. |
| **`Key` on both** | The fallback if it does collide. Rename the read model's instead; same cost, and *key* is the storage word (partition key, sort key), which the row key is. |
| Leave as is | Every doc that explains the row key has to say "Id, or Key on a state view". |

Either way, keep the other name as an alias for one window, and let the PPX inject the new one.

---

## 7. Rejected or refused

### 7.1 Today

*Refused* means three things:

| Where | Meaning |
|---|---|
| [`CommandTopic_Helpers.res`](../../reventless/core/src/components/CommandTopic/CommandTopic_Helpers.res) line 32 | the umbrella `refusalCause = DomainRejection \| InfrastructureFailure \| AccessRefusal` |
| [`Behavior_GWT.res`](../../reventless/gwt/src/Behavior_GWT.res) line 278, `thenRefused` | access refusal only (the caller may not act); a domain rejection is `thenError` |
| [`CheckLifecycleModel.res`](../../reventless/spec/src/lifecycle/CheckLifecycleModel.res) lines 598 and 649, `outcome = Refused` | a *domain* rejection, mapped from the sidecar's `"error"` kind |

On the wire a command's outcome is `CommandAccepted | CommandRejected | CommandPending`, and an
access refusal travels as `CommandRejected` with `errorCode: "Forbidden"`.

### 7.2 Alternatives and verdict

| Option | Verdict |
|---|---|
| **Rejected = the domain's no, refused = the platform's no** (access, infrastructure) | Recommended. Matches the wire (`CommandRejected`, `DomainRejection`) and the GWT (`thenRefused` is access). One rename: the lifecycle harvest's `Refused` becomes `Rejected`. |
| One word for both | Loses the distinction the GWT DSL already teaches and the umbrella type already names. |
| *Denied* for access | `AccessDenied` is IAM's word for an infrastructure error here; keep it out of the domain layer. |

Plain-language surfaces that call a declared error a *refusal* are describing a domain rejection;
the glossary should say that *refusal* in plain words is *rejection* in the framework.

---

## 8. Event handler or invocation handler

### 8.1 Today

[`Runtime.res`](../../reventless/core/src/adapter/Runtime/Runtime.res) line 1 still declares
`type eventHandler<'event, 'context, 'result>` for the function a Lambda or the local runtime
invokes with its *payload*, which is not a domain event.
[event-terminology-disambiguation.md](event-terminology-disambiguation.md) proposed
`invocationHandler<'payload, …>` for it and the dispatch dictionaries renamed to `*Dispatchers`.
None of that was applied.

### 8.2 Alternatives and verdict

| Option | Verdict |
|---|---|
| **`invocationHandler`, `'payload`**, as proposed | Recommended. Internal to the runtime layer; no application code names it. |
| `triggerHandler` | Equivalent; *invocation* is the cloud providers' own word. |
| Leave | *Event* keeps meaning two things in the one layer where the difference matters most. |

---

## 9. Multi-source or mixed-source

### 9.1 Today

The GWT DSL and the code say *multi-source*
([`MultiSourceProjection_GWT.res`](../../reventless/gwt/src/MultiSourceProjection_GWT.res)).
The docs say *mixed-source* in two page names and their prose
([`mixed-source-readmodel.md`](../../packages/doc/docs-app/mixed-source-readmodel.md),
[`mixed-source-automationslice.md`](../../packages/doc/docs-app/mixed-source-automationslice.md)),
about 20 files each way.

### 9.2 Verdict

*Multi-source*: rename the two pages and their prose. The identifier is the one that cannot move
without a window, and *multi* says "several" where *mixed* hints at "of different kinds", which
is not the point.

---

## 10. Terms that need a definition, not a rename

| Term | Problem | Where | Fix |
|---|---|---|---|
| **Delegate** | the local event source in an extension-point mapping, the local command target in an extension, and the GWT kind for the boundary (`Delegate_GWT`); none is in the glossary | [`extensionpoint.md`](../../packages/doc/docs-app/components/extensionpoint.md), [`plugin-system.md`](../../packages/doc/docs-app/plugin-system.md), [`Delegate_GWT.res`](../../reventless/gwt/src/Delegate_GWT.res) | One glossary entry: "the local component an extension point or extension stands in for; on the publishing side its events, on the consuming side its commands". The code is consistent; the docs never say it once. |
| **Port** | used for an extension point's translation table in two pages and the PPX, defined nowhere | [`extensionpoint.md`](../../packages/doc/docs-app/components/extensionpoint.md), [`extension.md`](../../packages/doc/docs-app/components/extension.md), [`TranslationTable.ml`](../../packages/reventless-ppx/src/ppx/TranslationTable.ml) | Replace the three uses with the component's name; cheaper than adding a word. |
| **Piece** vs **role** | the terminology guide says "role, not piece"; the module it governs says *piece* in its own comments | [`terminology-guide.md`](../guides/terminology-guide.md) line 98, [`ResourceAttribution.res`](../../reventless/core/src/ResourceAttribution.res) lines 12, 43, 108 | Replace in the comments; no identifier carries it. |
| **`apply`**, **`handle`** in doc examples | where the framework's functions are `evolve` and `decide` | [`application-development-layers.md`](../../packages/doc/docs-framework/application-development-layers.md) lines 111 and 699, [`commandgenerator.md`](../../packages/doc/docs-framework/runtime-components/commandgenerator.md) line 86, [`rescript-syntax.md`](../../packages/doc/docs-app/rescript-syntax.md) line 119 | Four edits, with the rename in [§3.4](#34-recommendation), which touches the same pages. |
| **Body suffix vs attribute** | `_Projections` pairs with `@@reventless.mappings`, `_Projection` with `@@reventless.projection`, `_Mappings` with `@@reventless.mappings` | [`Vocabulary.ml`](../../packages/reventless-ppx/src/ppx/Vocabulary.ml) lines 67 and 70 | Leave the names: the attribute names the shape (a list of per-source mappings, used by two file kinds) and the suffix names the output. Add the attribute column to the file-naming table so the pairing is visible. |
| **`type state`** | the decision model in a decision module; the stored row in a queryable spec | [`StateChangeSlice.res`](../../reventless/spec/src/components/StateChangeSlice.res), [`StateViewSlice.res`](../../reventless/spec/src/components/StateViewSlice.res) | Add a glossary entry *Row* beside *Decision model*. |
| **Refusal** (plain word) | a declared error in plain-language surfaces, a domain rejection in the framework | [§7](#7-rejected-or-refused) | Say so in the glossary's *Rejection* entry. |
| **GWT test suffixes** | framework tests are `*GwtTest.res`, example tests `*_GWT.res`; the PPX accepts `_GWT`, `GwtTest` and `Gwt` | [`GwtInference.ml`](../../packages/reventless-ppx/src/ppx/GwtInference.ml), [`reventless/gwt/tests/`](../../reventless/gwt/tests/) | Leave. The framework's own tests are not the form the docs teach, and the tolerance is cheap. |

---

## 11. Deliberate layering, leave alone

Named here so the next sweep does not re-find them.

- **Aggregate style and DCB style run parallel vocabularies** on purpose: `ReadModel` /
  `StateViewSlice`, `_Projections` / `_Projection`, `EventMapping` / `AutomationSlice`, and the
  shared umbrella `queryableDef` / `writableDef` over both.
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

## 12. Spelling

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

## 13. Order of work

1. The behavior → decision rename ([§3.4](#34-recommendation)), as one commit plus the PPX
   republish, with aliases. The doc-example edits of [§10](#10-terms-that-need-a-definition-not-a-rename)
   ride on it.
2. The glossary entries: *Chapter* and *Section* ([§4.4](#44-recommendation)), the *Plugin*
   extension ([§5.4](#54-recommendation)), *Delegate*, *Row*, *Rejection*
   ([§10](#10-terms-that-need-a-definition-not-a-rename)). Small enough for one docs commit.
3. The row key ([§6](#6-id-or-key-for-a-views-row-key)), its own commit, after the collision
   check.
4. The lifecycle harvest's `Refused` → `Rejected` ([§7](#7-rejected-or-refused)) and the
   runtime's `invocationHandler` ([§8](#8-event-handler-or-invocation-handler)), one commit each.
5. The *multi-source* page rename ([§9](#9-multi-source-or-mixed-source)) and the *port* /
   *piece* edits, one docs commit.
6. The spelling pass ([§12](#12-spelling)), docs only, after the renames so the former term is
   not re-spelled first.
7. Removal of the aliases after one release window.

---

## 14. Decisions

| Id | Question | Recommendation |
|---|---|---|
| D1 | Rename *behavior* to *decision*? | Yes: suffix `_Decision`, attribute `@@reventless.decision`, module `Decision.T`, DSL `Decision_GWT`, with aliases for one window ([§3.4](#34-recommendation)). |
| D2 | *Decider* or *decision* as the suffix? | *Decision*; *decider* is named in the glossary as the pattern ([§3.2](#32-alternatives)). |
| D3 | *Chapter* or *section*? | *Chapter* everywhere a framework concept is named; *section* stays for list-view groups and document parts ([§4.4](#44-recommendation)). |
| D4 | *Plugin* or *system*? | *Plugin*; glossary says it is a bounded context and that plain-language surfaces may gloss it as a separate system ([§5.4](#54-recommendation)). |
| D5 | `Id` or `Key` for a view's row key? | `Id` on both, unless the injected component `Id` collides, then `Key` on both ([§6](#6-id-or-key-for-a-views-row-key)). |
| D6 | What does *refused* mean? | The platform's no; *rejected* is the domain's no; the lifecycle harvest renames its `Refused` ([§7](#7-rejected-or-refused)). |
| D7 | Apply the earlier `invocationHandler` proposal? | Yes ([§8](#8-event-handler-or-invocation-handler)). |
| D8 | *Multi-source* or *mixed-source*? | *Multi-source*, in the docs ([§9](#9-multi-source-or-mixed-source)). |
| D9 | Prose spelling? | American throughout, matching the identifiers ([§12](#12-spelling)). |
