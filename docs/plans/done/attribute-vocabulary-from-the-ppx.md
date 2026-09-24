# Plan: the PPX says which attributes it reads, and where

**Status:** ✅ Done 2026-09-24. Released in 1.0.0-alpha.94.<br/>
**Touches:** `packages/reventless-ppx` only: a table in the `ReventlessPpx` library
(`src/ppx/Vocabulary.ml`), a flag on the reader's executable (`src/read/read.ml`), and the PPX tests.<br/>
**Companion:** reventless-tools `docs/plans/authoring-follows-the-framework-vocabulary.md`,
decision D3 ("the understood set is sourced, not typed") and its "Open, upstream" items. Also
reventless-tools `docs/plans/forms-as-views-of-the-source.md` L5a, where a field's attributes
are shown and edited in a form. Builds on [source-reader-with-spans](../source-reader-with-spans.md).

## Goal

`reventless-ppx-read --vocabulary` prints, as JSON, every attribute the PPX reads: its name,
the positions it is read in, whether it takes an argument, and one line saying what it does.
The list comes from one table in the `ReventlessPpx` library, and a test keeps that table
and the modules that read the attributes in step.

## Why

- **The PPX has no list of its attributes.** Each module matches the names it handles itself
  (`String.equal attr.attr_name.txt "…"`, `has_attr "…"`). About 45 authored names are matched
  across some 15 modules in `src/ppx/`, for example `DcbTagInference` (`partitionTag`,
  `dcbTag`, `noDcbTag`, `crossPartition`, `compositePartitionTag`), `StateAnnotations` (`id`,
  `lifecycle`, `index`, `subId`, `hidden`, `summary`, `internal`, `groupBy`, `live`, `retired`,
  `metric`), `SensitiveInference`, `StorageRefInference`, `DefaultInference`, `NoApiAnnotation`
  and `AuthorizationInjection`. Some names are read in several modules (`id` in four).
- **The reader cannot say what is accepted,** only what a file uses. Source-reader S1 promised
  that "the walk and the attribute list come from the `ReventlessPpx` library". The walk does,
  but there is no list for the reader to share.
- **Every other copy is transcribed, and drifts.**
  - The documentation's annotation vocabulary is hand-written. The documentation review found
    `@noApi` missing from it (`docs/analysis/documentation-journey-review.md`).
  - Tooling that offers attributes to an author has to keep its own list. One such list still
    offers `@status`, which `StateAnnotations.check_no_legacy_status_attr` now rejects at
    compile time.
  - A tool that follows the framework's vocabulary cannot do so without a list it can read.
    The precedent is `Semantic.brandedStrings`, which made the semantic-type list a value
    instead of something tools transcribe.
- **Positions matter as much as names.** `@partitionTag` is read on a command or event field,
  `@lifecycle` on a state field, and `@noApi` on a type. Offering an attribute where the PPX
  never reads it is as wrong as offering one it does not know.

## The shape

```json
{
  "version": "1.0.0-alpha.NN",
  "attributes": [
    {
      "name": "partitionTag",
      "positions": ["field.command", "field.event"],
      "args": "none",
      "summary": "The field this slice's events are filed under for consistency checks.",
      "readBy": ["DcbTagInference"]
    },
    {
      "name": "storageRef",
      "positions": ["field.state", "field.event"],
      "args": "required",
      "argsExample": "\"Catalog.productImages\"",
      "summary": "The object store an uploaded file in this field is kept in.",
      "readBy": ["StorageRefInference", "UploadableInference"]
    },
    {
      "name": "status",
      "positions": [],
      "args": "none",
      "summary": "Renamed. Use @lifecycle.",
      "replacedBy": "lifecycle",
      "readBy": ["StateAnnotations"]
    }
  ]
}
```

The entries above show the shape. Their positions and summaries are illustrative until S0
records what the code does.

- **`positions`** is a closed list, decided in S0: fields of a `command`, `event`,
  `consumedEvent` and `state`, fields of a named record, a variant case, a type, and a file
  (`@@…`). An attribute read in no position today, but still recognised to refuse it, has none
  and says `replacedBy`.
- **`args`** is `none`, `optional` or `required`. `argsExample` is source text, as written.
  Parsing an argument into a value stays with the module that reads it.
- **`summary`** is one sentence for someone choosing the attribute, not a specification. It is
  kept in the table, next to the name, so it changes when the name's meaning does.
- **`readBy`** names the modules that read it, so a reader of the table can find the behaviour.
- **Not listed:** `res.*` (the parser's printing hints, `SourceReader.is_authored`), `schema`,
  `s.*` (sury's own), and the `reventless.*` attributes the PPX writes itself.

## S0 — Inventory

- Read every module in `src/ppx/` and record, for each attribute name it matches: the positions
  it is read in (by where the match happens: a `label_declaration` under which type, a
  `constructor_declaration`, a `type_declaration`, a structure item), whether it reads a payload,
  and what it does with the attribute.
- Decide the position list from what the code does, not from what the documentation says.
- **Exit:** a table, written into this plan, covering every name the modules match. A name
  matched only to refuse it (`status`) is in the table with `replacedBy`.

### S0 result

60 names, matched in 17 modules. The code differs from the plan's sketch in these places:

- **Positions.** Cases and types need an owner too, not only fields. `@authorize` and
  `@noApi` are read on a command's cases, and `@live` and `@namedWhenRetired` on the state
  type, so offering them on any case or type would be wrong. The list is closed at `file`,
  `module`, and `type.<owner>`, `case.<owner>` and `field.<owner>`. The owner is `command`,
  `event`, `consumedEvent`, `state` or `other`, where `other` is any other type: a named
  record, an enum, or another variant. `module` is new: `@reventless.delegate` is read on a
  module binding.
- **Where a pass reads.** `@ref`, `@storageRef`, `@offload`, `@owner`, `@sensitive` and
  `@default` are read on every field in a spec file, including a state's, whatever the
  documentation says each is for. The DCB passes read the fields of a `@schema` variant.
  Those are listed as the command's, event's and consumedEvent's fields, and the rarer
  variants (`sourceEvent`, `inboundCommand`) are left out. The rest of the state annotations
  are read on state fields only.
- **Where a read has an effect.** `@noApi` is read on every `@schema` type, but only a
  command's schema is consumed, so its positions are `type.command` and `case.command`.
- **Refusals.** The table has six attributes that are recognised only to be refused:
  `@status` (use `@lifecycle`), `@noTag` (use `@noDcbTag`),
  `@reventless.projections` (use `@@reventless.mappings`), and `@transition`,
  `@allowedStates` and `@targetState`. The last three have no `replacedBy`, because they
  were replaced by a `commandTransition` value rather than by another attribute. The
  documentation still describes `@allowedStates` in `packages/doc/docs-app/reventless-ppx.md`.
- **Not listed:** also `ocaml.*` (`ocaml.ppx.context`, which the compiler adds). No
  `reventless.*` attribute is written by the PPX itself. The one attribute it synthesises,
  `@id` on a view's key field, is also written by authors.

The patterns: the name compared with `attr_name.txt`, passed to `has_attr` / `find_attr` /
`attr_is`, or compared in `is_ppx_attr`; the name held in a `let …attr… = "…"`
constant; and the names in `TaggedUnionInference.refused_field_attrs`,
`TransitionAnnotation.removed_attrs` and `ReventlessPpx.impl_kind_attr_name`.

| Attribute | Positions | Args | Read by |
|---|---|---|---|
| `@@reventless.spec` | `file` | optional | ReventlessPpx |
| `@@reventless.behavior` | `file` | optional | ReventlessPpx |
| `@@reventless.projection` | `file` | optional | ReventlessPpx |
| `@@reventless.automation` | `file` | optional | ReventlessPpx |
| `@@reventless.translation` | `file` | optional | ReventlessPpx |
| `@@reventless.mappings` | `file` | optional | ReventlessPpx |
| `@@reventless.extension` | `file` | optional | ReventlessPpx |
| `@@reventless.task` | `file` | optional | ReventlessPpx |
| `@@reventless.dcbTags` | `file` | none | ReventlessPpx |
| `@@reventless.async` | `file` | none | ReventlessPpx |
| `@@reventless.systemCallable` | `file` | none | ReventlessPpx |
| `@@reventless.gwt` | `file` | optional | GwtInference |
| `@@reventless.visibility` | `file` | required | VisibilityInjection |
| `@@reventless.authorize` | `file` | required | AuthorizationInjection |
| `@@reventless.consistency` | `file` | required | ReadConsistencyInjection |
| `@@reventless.snapshots` | `file` | required | SnapshotInjection |
| `@@reventless.examples` | `file` | none | SidecarEmit |
| `@reventless.delegate` | `module` | none | ReventlessPpx |
| `@reventless.projections` | — (refused; use `@reventless.mappings`) | none | ReventlessPpx |
| `@noApi` | `type.command`, `case.command` | none | NoApiAnnotation, ReventlessPpx |
| `@authorize` | `case.command` | required | AuthorizationInjection |
| `@live` | `type.state` | required | StateAnnotations |
| `@namedWhenRetired` | `type.state` | none | StateAnnotations |
| `@transition` | — (refused) | none | TransitionAnnotation |
| `@allowedStates` | — (refused) | none | TransitionAnnotation |
| `@targetState` | — (refused) | none | TransitionAnnotation |
| `@partitionTag` | `field.command`, `field.event`, `field.consumedEvent` | none | DcbTagInference, SidecarEmit |
| `@crossPartition` | `field.command`, `field.event`, `field.consumedEvent` | none | DcbTagInference |
| `@dcbTag` | `field.command`, `field.event`, `field.consumedEvent` | optional | DcbTagInference, SidecarEmit |
| `@compositePartitionTag` | `field.command`, `field.event`, `field.consumedEvent` | optional | DcbTagInference, SidecarEmit |
| `@noDcbTag` | `field.command`, `field.event`, `field.consumedEvent`, `field.state`, `field.other` | none | DcbTagInference, ReferenceInference, SidecarEmit |
| `@noTag` | — (refused; use `@noDcbTag`) | none | DcbTagInference |
| `@ref` | `field.command`, `field.event`, `field.consumedEvent`, `field.state`, `field.other` | required | ReferenceInference |
| `@storageRef` | `field.command`, `field.event`, `field.consumedEvent`, `field.state`, `field.other` | required | StorageRefInference, UploadableInference |
| `@offload` | `field.command`, `field.event`, `field.consumedEvent`, `field.state`, `field.other` | required | OffloadInference |
| `@owner` | `field.command`, `field.event`, `field.consumedEvent`, `field.state`, `field.other` | optional | OwnerInference, StateAnnotations |
| `@sensitive` | `field.command`, `field.event`, `field.consumedEvent`, `field.state`, `field.other` | none | SensitiveInference |
| `@default` | `field.command`, `field.event`, `field.consumedEvent`, `field.state`, `field.other` | required | DefaultInference |
| `@displayName` | `field.state` | optional | DisplayNameInference |
| `@id` | `field.state` | none | StateAnnotations, TaggedUnionInference, SidecarEmit |
| `@compositeId` | `field.state` | optional | StateAnnotations, TaggedUnionInference, SidecarEmit |
| `@subId` | `field.state` | none | StateAnnotations, TaggedUnionInference |
| `@compositeSubId` | `field.state` | optional | StateAnnotations, TaggedUnionInference, SidecarEmit |
| `@index` | `field.state` | optional | StateAnnotations, TaggedUnionInference, SidecarEmit |
| `@indexSubId` | `field.state` | required | StateAnnotations, TaggedUnionInference |
| `@resolves` | `field.state` | required | StateAnnotations |
| `@resolvesMany` | `field.state` | required | StateAnnotations |
| `@lifecycle` | `field.state` | none | StateAnnotations, TaggedUnionInference |
| `@status` | — (refused; use `@lifecycle`) | none | StateAnnotations |
| `@groupBy` | `field.state` | none | StateAnnotations, TaggedUnionInference |
| `@retired` | `field.state`, `case.other` | optional | StateAnnotations, TaggedUnionInference |
| `@hidden` | `field.state` | none | StateAnnotations |
| `@summary` | `field.state` | none | StateAnnotations |
| `@internal` | `field.state` | none | StateAnnotations |
| `@drillTarget` | `field.state` | required | StateAnnotations |
| `@collapsed` | `field.state` | none | StateAnnotations |
| `@scan` | `field.state` | none | StateAnnotations, TaggedUnionInference |
| `@scanSort` | `field.state` | none | StateAnnotations, TaggedUnionInference |
| `@semantic` | `field.state` | required | StateAnnotations |
| `@metric` | `field.state` | required | StateAnnotations |

## S1 — One table

- `src/ppx/Vocabulary.ml`: `type position`, `type args`, `type entry = {name; positions; args;
  args_example; summary; replaced_by; read_by}`, and `all : entry list`, from S0.
- The modules keep their own matching. Moving each one onto the table is not needed for the
  table to be right, and would touch every module at once.
- **A drift guard keeps it right.** A test lists every string literal compared with an
  attribute name in `src/ppx/*.ml` (the patterns S0 used) and fails when a name is matched
  there but missing from `Vocabulary.all`, or listed there but matched nowhere. Adding an
  attribute to a module without adding it to the table fails the build's tests.
- **Exit:** the guard passes on the current sources, and fails on a test fixture that matches
  a name the table does not list.
- **Done:** `src/test_vocabulary`, run by `dune build @runtest`. It also checks that each
  entry's `readBy` names exactly the modules that match it, and that the list has no name
  twice.

## S2 — The reader prints it

- `reventless-ppx-read --vocabulary` prints the table as the JSON above, with the PPX's own
  version. It takes no file and needs no `bsc`, so it answers in milliseconds.
- **Tests:** the output is valid JSON with an entry for every name in `Vocabulary.all`. A
  golden file pins the output, so a changed summary or position shows up in review.
- **Docs:** the reader's section in `docs/guides/reverse-codegen-pipeline.md` describes the
  flag. The documentation's hand-written annotation list says that the reader's vocabulary is
  the complete list.
- **Done.** The `version` is read when the flag runs, from the `package.json` of the package
  the binary is in: the per-platform package once it is installed, or the PPX package above a
  local build. It cannot be compiled in, because the release resolves the version after the
  build. The golden (`test/golden/vocabulary.golden.json`) replaces it with `<version>`.
  `reverse-codegen-pipeline.md` had no section on the reader, so this adds one.

## S3 — Release

The PPX release procedure, as in [gwt-sidecar-refs-and-examples.md](../gwt-sidecar-refs-and-examples.md)
R3. **Exit:** the published PPX prints its vocabulary. The companion plans then close their
upstream item, and replace their transcribed lists with this output.

- **Done: 1.0.0-alpha.94.** The published darwin-arm64 `read.exe --vocabulary` prints version
  `1.0.0-alpha.94`, and its output matches the golden file. The release's first drift-guard run
  gave up waiting for the linux-x64 tarball, which the registry served about ten minutes after
  publishing; a re-run passed. That wait is gone since: each build job now tests its packed
  tarball before publishing it, and the git pin moved to `pin-ppx.yml`.

## Risks

- **A position missed in S0.** A reader offers an attribute in fewer places than the PPX reads
  it. The failure is under-offering, never a wrong offer, and the fix is one table row.
- **Summaries go stale.** They sit next to the name in one table, and the golden output makes
  every change visible in review. They are still prose, and are reviewed as such.
- **Version skew.** A reader asks the reader binary installed with the app, so it gets the
  vocabulary of the PPX that app compiles with, not of the newest release.

## Not in scope

- **Refusing unknown attributes.** The table makes a warning for an attribute the PPX does not
  read possible. Whether to warn, and where, is a separate decision.
- **Argument schemas.** `args` says whether there is one. What a valid argument is stays with
  the module that reads it.
- **Moving the modules onto the table.** Possible once the table exists. The drift guard makes
  it unnecessary for correctness.
