# Plan: why a read model is named by that field

**Date:** 2026-07-29
**Status:** IMPLEMENTED (2026-07-29) — all four phases landed; verified on the
wire against two live local platforms (see Verification).
**Predecessor:** [read-model-label-field.md](../read-model-label-field.md) — this
is the one item that plan deferred for want of a consumer.

## Motivation

`labelFieldsFromStateSchema` resolves the field a read model is named by, down a
four-rung ladder
([Plugin_Structure.res:92](../../../reventless/core/src/plugin/component/Plugin_Structure.res)):

1. A `@displayName` spec → `"displayName"` (the projected composite column).
2. A candidate field named `name` / `title` / `label` / `displayName`.
3. The first candidate in declaration order.
4. `"id"`, with a warning.

`queryableDef` publishes the *result* and not the rung. Rung 1 is the author
saying which field names the record; rungs 2 and 3 are guesses this repo makes
on their behalf, and rung 4 is an admission that there is nothing to guess from.
On the wire all four are one `String!`, so a consumer reading

```
labelField: "displayName"
```

cannot tell it from

```
labelField: "email"
```

— the first is a declaration, the second is whichever string happened to be
declared first. That difference is the whole basis on which a consumer should
decide whether to *believe* the field or to prefer a rule of its own, and it is
exactly the difference the wire drops.

The consequence is not hypothetical, and it is not this repo's to fix: a client
that renders records has its own name rule (it must — it also renders nested
collections, which have no `queryableDef` at all), and with no provenance it can
only rank the declaration wholesale. Rank it *above* the local rule and a
positional guess about `email` overrides a field literally named `name`; rank it
*below* and an explicit `@displayName` loses to the same field. Both orderings
are wrong for half the ladder, and the client cannot pick per-case because the
datum that distinguishes the cases is not sent.

Rung 4 is the one part already visible, and only by inference: `labelField ==
"id"` means the ladder bottomed out, which is why a consumer can decline it.
That is provenance leaking through a value, for one rung out of four.

## Scope

| In | Out |
|---|---|
| `labelFieldsFromStateSchema` returns the rung it used alongside the field | Changing which field any rung picks — the ladder is unchanged |
| `queryableDef.labelFieldSource`, optional, absent on defs written before it | A per-field annotation for "this is the label" — `@displayName` is that annotation |
| The SDL type + JSON encoder shared by the in-memory and AWS adapters | Provenance for `statusField` — its two rungs are annotation and exact-name, and nothing reads it ambiguously yet |
| Hand-rolled `queryableDef`s declaring their own source | Provenance for `searchableFields` — it is derived from the same pick and moves with it |
| Tests pinning one case per rung | Any consumer's ranking policy — that belongs to the consumer |

## Design decisions

1. **Publish the rung, not a confidence.** `"annotation"` / `"convention"` /
   `"position"` / `"fallback"` name where the answer came from. A boolean
   (`isDeclared`) would collapse rungs 2 and 3, which is the collapse a consumer
   needs undone: a field named `name` is a guess that agrees with every client's
   own guess, while a positional pick is a guess that does not. A numeric
   confidence would invent a scale nothing measures.

2. **`option<string>` on the def, like `visibility` and `statusField`.** A
   variant would be type-safe here and lossy across the wire's edges: defs
   persisted before this field existed decode as `None`, and a consumer built
   against four values must not fail to parse a fifth this ladder grows later.
   `None` means "not stated", which is what an old def truthfully is — and is
   distinct from `Some("fallback")`, which is this repo stating that it looked
   and found nothing.

3. **The resolver returns a record, not a wider tuple.**
   `labelFieldsFromStateSchema` already returns `(field, searchableFields)` and
   three of its five call sites discard the second element. A third positional
   element makes every call site restate which is which; `{field,
   searchableFields, source}` names them once. The rung is decided in the one
   place the field is decided — a second function that re-walked the ladder to
   report on it would be the duplication [read-model-label-field.md](../read-model-label-field.md)
   removed.

4. **`"convention"` and `"position"` stay distinct even though this repo treats
   them identically.** Both are guesses and both pick a real field, so nothing
   here branches on the difference. The consumer is where the difference lands:
   a conventional name is the one guess a client can independently arrive at, so
   agreeing with it is not evidence of anything, whereas a positional pick is a
   fact only this repo knows.

## Phases

### Phase 1 — the resolver reports its rung

`Plugin_Structure`:

```rescript
type labelFieldSource = Annotation | Convention | Position | Fallback

type labelResolution = {
  field: string,
  searchableFields: array<string>,
  source: labelFieldSource,
}

let labelFieldSourceToString: labelFieldSource => string
```

`labelFieldsFromStateSchema` returns `labelResolution`; each of its four exits
names its rung. The five call sites (`Plugin_Structure` ×2, `Plugin_Builder`,
`Platform_Admin`, `Dcb_Builder`) read `.field` / `.searchableFields`.

### Phase 2 — the def carries it

`Reventless.Plugin.queryableDef` gains
`labelFieldSource: @s.matches(stringOptionSchema) option<string>`, documented
with the vocabulary and with what `None` means. The two def-building sites in
`Plugin_Structure` set it from the resolution; `Platform_Admin_Structure`'s
hand-rolled `pluginReadModel` states its own (`"convention"` — it declares
`labelField: "name"`).

### Phase 3 — the wire

`Platform_ComponentDefinitionsApi`: `labelFieldSource: String` on the
`Platform_ReadSideDef` SDL type, and one line in `encodeQueryableDef`. Both
adapters resolve through this module, so they stay byte-identical.

### Phase 4 — tests

`PluginStructureTest`: one case per rung — a `@displayName` state
(`"annotation"`), a state with a `name` field beneath an earlier string
(`"convention"`), a state whose only candidate is positional (`"position"`), and
a state with no candidate (`"fallback"`, `labelField: "id"`). The existing
expectations keep their tuple shape through the test helper, so this plan adds
assertions rather than rewriting them.

## Verification

`pnpm test` — 276 suites, 2291 tests, green.

The resolver run over every spec module under `examples/`:

| App | View | `labelField` | `labelFieldSource` |
|---|---|---|---|
| dcb, hybrid | `Ordering.Customers` | `displayName` | `annotation` |
| aggregates | `Ordering.Customers` | `email` | **`position`** |
| all three | `Catalog.Products`, `Categories`, `AvailableProducts`, … | `name` | `convention` |
| all three | `Ordering.Orders` | `id` | `fallback` |

Row 2 is the one worth reading: the same entity, modelled without the
annotation, is named by whichever string was declared first — and until now a
consumer was told only `"email"`.

Then `Platform_ComponentDefinitions` against a running `online-shop-aggregates`
and `online-shop-hybrid` local platform (in-memory backend, admin token). Every
read side and state-view slice answers with its rung, including
`Platform.Plugins`, whose def is hand-rolled and states `"convention"` for
itself.

## Deferred

- **Provenance for `statusField`.** Same shape of question, no consumer with the
  same problem: its rungs are `@status` and a field literally named `status`
  whose IR shape is an enum, and a client's own status rule looks for the same
  thing. Revisit if a client starts ranking its own status inference against the
  declaration.
- **Publishing the *fields* a composite label was built from as provenance.**
  `searchableFields` already lists them for the `@displayName` case, which is
  the only case where a label has sources at all. A consumer wanting to explain
  a composite label to a human can read them there.
