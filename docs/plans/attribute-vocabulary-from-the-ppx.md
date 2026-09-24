# Plan: the PPX says which attributes it reads, and where

**Status:** 📝 Proposed 2026-09-24.<br/>
**Touches:** `packages/reventless-ppx` only: a table in the `ReventlessPpx` library
(`src/ppx/Vocabulary.ml`), a flag on the reader's executable (`src/read/read.ml`), and the PPX tests.<br/>
**Companion:** reventless-tools `docs/plans/authoring-follows-the-framework-vocabulary.md`,
decision D3 ("the understood set is sourced, not typed") and its "Open, upstream" items. Also
reventless-tools `docs/plans/forms-as-views-of-the-source.md` L5a, where a field's attributes
are shown and edited in a form. Builds on [source-reader-with-spans](source-reader-with-spans.md).

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

## S2 — The reader prints it

- `reventless-ppx-read --vocabulary` prints the table as the JSON above, with the PPX's own
  version. It takes no file and needs no `bsc`, so it answers in milliseconds.
- **Tests:** the output is valid JSON with an entry for every name in `Vocabulary.all`. A
  golden file pins the output, so a changed summary or position shows up in review.
- **Docs:** the reader's section in `docs/guides/reverse-codegen-pipeline.md` describes the
  flag. The documentation's hand-written annotation list says that the reader's vocabulary is
  the complete list.

## S3 — Release

The PPX release procedure, as in [gwt-sidecar-refs-and-examples.md](gwt-sidecar-refs-and-examples.md)
R3. **Exit:** the published PPX prints its vocabulary. The companion plans then close their
upstream item, and replace their transcribed lists with this output.

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
