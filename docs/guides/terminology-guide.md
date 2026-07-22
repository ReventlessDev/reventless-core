# Terminology Guide

The vocabulary the framework uses for its own structure, and the rules that keep those words
meaning one thing. This is the **framework-internal** reference: the layering, the two tiers that
are both called "component", and the attribution vocabulary that deployed resources are tagged
with.

For the application-developer vocabulary (Aggregate, Projection, Slice, Spec, …) see the published
[glossary](../../packages/doc/docs-app/glossary.md), served at `/app/glossary`. This guide does not
restate those terms; it defines the ones the glossary does not cover and fixes the ambiguities the
glossary is silent on.

---

## The hierarchy

```
Platform            the top-level deployment unit; owns shared infrastructure
└── Plugin          the deployable unit of an application
    └── Component   what an application developer writes (Aggregate, ReadModel, Slice, …)
        └── role    the job one provisioned resource does for that component
```

Each level owns the one below it. That ownership is exactly what the deploy tags record, so the
hierarchy and the tag schema are the same statement in two forms.

Groupings *above* Platform — several platforms viewed together — are deliberately **not** a core
concept. They own nothing: such a view is derived from the `reventless:platform` and
`reventless:environment` facts that every resource already carries. There is no shared consistency
boundary across platforms, so there is no level above Platform to own resources.

---

## Core vs Platform

These two are the most-confused pair in the codebase, because "core" was used for the platform
before the platform term settled.

**Core** is a *code-organisation* term. It names the framework layer — the `reventless-core`
package and the `ReventlessCore` namespace. Use it when talking about where code lives ("that
belongs in core, it is provider-neutral").

> **Core is never a deployment or model term.** It does not name a thing that gets deployed, and it
> does not own resources.

**Platform** is a *deployment and model* term. It is the top-level unit that assembles plugins and
provisions shared infrastructure (the API surface, authentication, hosting, scheduling). It is also
a model element in its own right: platform-level substrate is attributed to it.

The framework's own built-in plugin is named **`Platform`** (`Platform_Admin_Structure.pluginId`).
It hosts the platform's administrative components — the Plugin aggregate, its read model, the
lifecycle extension point, the cloner.

### Historical drift — do not copy these

Several identifiers and comments still say "core" where they mean the platform. They are stale, not
a second meaning:

| Stale usage | What it actually is |
|---|---|
| "Core Plugin" (heartbeat, IAM comments) | the built-in plugin, which is named `Platform` |
| `Util_StackRefs.coreStackName`, `Interstack.coreStackReference` | the **platform** stack — both read the `platform` config namespace |
| "core API", "core schema", `coreApi` (split mode) | the **platform** API, as opposed to the per-plugin APIs |
| `ComponentType.Core` | vestigial; platform-level things are `ComponentType.Platform` |

---

## Two tiers are both called "component"

The word `component` spans two levels, and this is the single most load-bearing ambiguity in the
framework's vocabulary:

- **Model components** — what an application developer writes and names: Aggregate, ReadModel,
  StateChangeSlice, StateViewSlice, AutomationSlice, the translation slices, ExtensionPoint, Task.
- **Infrastructure components** — what those are *built from*: EventLog, QueryDb, CommandTopic,
  EventTopic, EventCollector, CommandGenerator, EventMapper. These are components in the literal
  sense too — each is constructed through `Component.make` with its own `componentType`.

`ComponentType.t` holds both tiers in one enum. That is why an infrastructure adapter passing "its
own" component type names the *lower* tier, and why the attribution schema needs a separate word
for it (see `role`, below).

> **Do not split `ComponentType.t` casually.** `ComponentType.toString` feeds
> `Component.make(~componentType=)`, which is the **Pulumi resource type token** — it appears in
> resource URNs. Renaming or re-partitioning those variants changes URNs and causes resource
> replacement on the next deploy. Adding a variant is safe; renaming an existing one is not.

---

## Attribution vocabulary

Every framework-created resource is tagged with four independent facts. They answer: *which model
element owns this, doing what job, at what level.*

| Term | Type | Tag | Answers |
|---|---|---|---|
| **kind** | `ComponentType.t` | `reventless:kind` | *what the owner is* — Aggregate, ReadModel, StateViewSlice, Plugin, Platform |
| **role** | `ResourceAttribution.Role.t` | `reventless:role` | *what job this resource does* — EventLog, QueryDb, Runtime, Identity, Logs, DeadLetter, … |
| **scope** | `ResourceAttribution.Scope.t` | `reventless:scope` | *at which level it is owned* — `component`, `plugin`, `platform` |
| **owner** | `ResourceAttribution.owner` | (not a tag) | the deploy-time record `{kind, name}` that carries the first fact down to the adapter |

`kind` and `role` are independent on purpose. One component owns several resources in different
roles (an Aggregate has an EventLog, a CommandTopic, a Runtime), and one role is played under many
kinds (a QueryDb is owned by a ReadModel, a StateViewSlice, an AutomationSlice, a translation
slice, or a Counter). Collapsing them — which the schema did historically — makes both questions
unanswerable.

**"Role", not "piece".** The job a resource does for its owner is a *role*. That is the word in the
type, in the tag key, and in prose. Avoid inventing a parallel noun ("piece", "part") for the same
concept.

### Ownership is never absent

A resource with no single owning *component* is not ownerless — it is owned by the level above.
Shared substrate (a plugin's DCB event log, its dead-letter queue, its command topics) is owned by
the **Plugin**; the API surface, authentication and hosting are owned by the **Platform**. Those
resources carry `kind = Plugin` / `kind = Platform` and the matching scope, with
`reventless:component` empty because the plugin and platform fields already name the owner.

### The full tag set

Eight keys. Seven namespaced framework facts, and exactly one bare key:

`Name`, `reventless:platform`, `reventless:plugin`, `reventless:component`, `reventless:kind`,
`reventless:role`, `reventless:scope`, `reventless:environment`.

Every framework fact is namespaced `reventless:`, lower-case, and appears once. `Name` is bare
because the AWS console reads that literal spelling for its resource-name column — it is the sole
exception, and no new bare keys should be added. On other backends the same facts are expressed as
that platform's idiomatic labels; the vocabulary is one, the spelling is per-platform.

---

## Naming rules

1. **Core names a code layer, never a deployed thing.** If it gets provisioned, it belongs to a
   Platform, a Plugin, or a Component.
2. **Say which tier you mean** when writing "component" in a comment — model or infrastructure.
3. **One word per concept.** The job a resource does is a `role`; do not introduce synonyms.
4. **Ownership rolls up, never disappears.** Attribute substrate to its plugin or platform rather
   than leaving it unattributed.
5. **Adding a `ComponentType` variant is cheap; renaming one is a deploy event.** See the warning
   above.
