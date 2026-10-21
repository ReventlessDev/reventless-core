# Plan: the framework's smaller vocabulary cleanups

**Status:** ✅ Done 2026-10-21: [V1](#v1-glossary-entries) to [V7](#v7-american-spelling-in-prose) all done.<br/>
**Derived from:** [framework-vocabulary-behavior-chapter-and-doubled-terms.md](../analysis/framework-vocabulary-behavior-chapter-and-doubled-terms.md),
its [order of work](../analysis/framework-vocabulary-behavior-chapter-and-doubled-terms.md#14-order-of-work)
and [decisions](../analysis/framework-vocabulary-behavior-chapter-and-doubled-terms.md#15-decisions).<br/>
**Not here:** the behavior-to-decision rename, which is
[the-logic-module-is-called-the-decision.md](the-logic-module-is-called-the-decision.md), and the
rejection cause, which is [a-rejection-says-its-cause.md](a-rejection-says-its-cause.md).

## In plain words

The vocabulary analysis found a handful of words that mean two things, or two words for one
thing, besides the big rename. Each fix is small, and none depends on another, so each is its
own commit, numbered V1 to V7. Most are docs; three change identifiers.

## Phases

### V1. Glossary entries

Docs only, in `packages/doc/docs-app/glossary.md`:

- **Chapter**: the first non-kind folder under `src/`, carried as `chapter` on every component
  definition, used by the UI to group components and by the DCB partition inference to break
  ties. Set against **Section**, which means a list page's row groups (`@groupBy`) and a part of
  a document.
- **Plugin**: add that it is a bounded context (its own model, its own event log, no shared
  tables), that plain-language surfaces may call it "a separate system", and that the platform's
  own *Plugin aggregate* is the registry of plugins.
- **View**: a read-side component, a ReadModel or a StateViewSlice; in the code and the platform
  API its definition is a read-side def.
- **Projection**, rewritten: the function that folds one event into a view's row, in both styles.
  **ReadModel**, rewritten: the aggregate-style view, without calling it a projection.
  **StateViewSlice**: drop "or validation".
- **Error** and **Rejection**: a spec's error is a named reason a decision rejects a command,
  not a failure; the outcome a client sees is a rejection; a plain-language *refusal* is a
  declared error.
- **Delegate**: the local component an extension point or extension stands in for; on the
  publishing side its events, on the consuming side its commands.
- **Row**, beside **Decision model**: the stored record of a view, its `type state`.

### V2. Pages, not views, for what the UI draws

Docs only. The list view, detail view and board of a view become its *list page*, *detail
page* and *board page*, about 50 mentions under `packages/doc` and `docs/guides`. Identifiers
stay, `viewModes` included.

### V3. `queryableDef` becomes `readSideDef`

Source only, no wire change:

- `queryableDef` → `readSideDef`, `writableDef` → `writeSideDef` in `reventless/spec`,
  `isPublicQueryable` → `isPublicReadSide`, `encodeQueryableDef` → `encodeReadSideDef`, and
  every reader in core, aws and local.
- The platform API's `Platform_ReadSideDef`, `Platform_WriteSideDef` and the field
  `internalQueryables` stay as they are. `check:graphql` proves the schema did not move.
- No alias; the compiler names every reader, including downstream ones on their next bump.

### V4. A state view's row key is `Id`

- The PPX stops injecting the generic `module Id = Reventless.Id.String` into `StateView/` and
  `StateViewStream/` files, and injects the row key as `module Id = Reventless.Id.StringPure`
  where it injects `Key` today. A hand-written `module Id = OrderId` suppresses the injection.
- A hand-written `module Key` in such a file is a compile error naming `module Id`.
- `StateViewSlice.Spec` requires `module Id: Id.T`; `StateViewSlice_Builder`,
  `StateViewSlice_Callback`, `Projection_GWT` and the runtimes read `Spec.Id`.
- The eleven views in the examples that declare `module Key = …` change to `module Id = …`, as
  do the gwt and local test fixtures.
- Republish the PPX with the core packages. The build that drops the generic injection is the
  proof that nothing read it
  ([§7.2 of the analysis](../analysis/framework-vocabulary-behavior-chapter-and-doubled-terms.md#72-what-the-collision-check-found)).
- `CLAUDE.md`: the `@@reventless.spec` paragraph says `module Id`, not `module Key`. The
  paragraph lives in `.claude/rules/app-developer.md`.

### V5. Two identifiers that say the wrong thing

One commit each:

- **The lifecycle harvest.** `CheckLifecycleModel.res`: `outcome = Emitted | NoChange | Refused`
  becomes `… | Rejected`. It names a domain rejection, mapped from the sidecar's `"error"`
  kind. `check:lifecycle` must pass unchanged, since the committed lifecycle models do not
  carry the word.
- **The runtime's handler.** `Runtime.res`: `eventHandler<'event, 'context, 'result>` becomes
  `invocationHandler<'payload, 'context, 'result>`, and `effectHandler` follows, as
  [event-terminology-disambiguation.md](../analysis/event-terminology-disambiguation.md)
  proposed. Internal to the runtime layer.

### V6. Three stray words in the docs

One docs commit:

- `mixed-source-readmodel.md` and `mixed-source-automationslice.md` become
  `multi-source-…`, with their sidebar entries, their inbound links and their prose, matching
  `MultiSourceProjection_GWT`.
- *Port*, in `components/extensionpoint.md`, `components/extension.md` and the PPX's
  `TranslationTable.ml` comment, is replaced with the component's name.
- *Piece* in `ResourceAttribution.res`'s comments becomes *role*, as the terminology guide
  says.

### V7. American spelling in prose

Docs and comments only, after [V1](#v1-glossary-entries) to [V6](#v6-three-stray-words-in-the-docs) so nothing is respelled twice:

- Replace *behaviour, honour, favour, colour, recognise, organise, licence, catalogue,
  modelling* and their inflections with the American spelling under `docs/`, `packages/doc`,
  `CLAUDE.md`, `.claude/rules/` and source comments. About 400 hits.
- Add `scripts/check-spelling.mjs` and `pnpm run check:spelling`, run by hand before a docs
  commit, not in CI: it lists British spellings of those words outside code blocks.
- Quoted text and external names (a CloudFront "behavior", a quoted title) are left as written.

## Verification

Per phase, besides the root build with zero warnings and `pnpm test`:

| Phase | Check |
|---|---|
| [V1](#v1-glossary-entries), [V2](#v2-pages-not-views-for-what-the-ui-draws), [V6](#v6-three-stray-words-in-the-docs), [V7](#v7-american-spelling-in-prose) | the docs site builds (`pnpm --filter ./packages/doc run build`), so no link broke |
| [V3](#v3-queryabledef-becomes-readsidedef) | `check:graphql` unchanged; `git grep queryableDef` empty |
| [V4](#v4-a-state-views-row-key-is-id) | `check:fresh-outputs`, `check:traits`; a fixture with `module Key` fails with the message |
| [V5](#v5-two-identifiers-that-say-the-wrong-thing) | `check:lifecycle` unchanged |
