# Plan: the model sidecar keeps an annotation's argument

**Status:** 🚧 S1 done — 2026-09-24; S2 (release) open.<br/>
**Touches:** `packages/reventless-ppx` only (`src/ppx/SidecarEmit.ml`, `src/ppx/SourceReader.ml`,
`src/test_sidecar/`, `test/run.sh`) and `docs/guides/reverse-codegen-pipeline.md`.<br/>
**Companion:** reventless-tools `docs/plans/authoring-follows-the-framework-vocabulary.md`,
Phase 3, "Open, upstream". That phase made the tools carry a field's annotations as
`{name, args}` through the form, the model, the emitter and the parser. The one gap left is
this sidecar.

## Goal

A field's `annotations` in a `<Stem>.model.json` sidecar say what the source says, argument
included: `@storageRef("Catalog.productImages")` reaches a reader as that, not as
`"storageRef"`.

## Why

`SidecarEmit.attr_names` (`SidecarEmit.ml:35`) keeps an attribute's name and nothing else, and
`field_json` (`:173`) writes that list as the field's `annotations`. So a model assembled from
sidecars (reventless-tools `codegen/src/reverse/Assemble.res`) has lost every argument.

- **What is lost today,** on `examples/online-shop-hybrid`'s 41 spec files: `@storageRef(…)`
  three times, `@default(1)` once, and `@ref(…)` once. `@ref` has had its own `ref` key since
  alpha.86 ([model-sidecar-refs](done/model-sidecar-refs.md)). The other field annotations
  there, eleven kinds, take no argument.
- **What it costs.** The tools' emitter now writes a field's annotations back
  (`SpecEmitter.renderField`). For a sidecar-assembled model it would write a bare
  `@storageRef`, which does not compile. No tools path emits such a model yet, because forward
  starts from the Event Model import. But the round trip the tools are building (code → model
  → code) cannot close while the sidecar drops arguments. The same loss means an author reading
  a model cannot see where a field's images are stored, or what its default is.
- `@ref` was fixed alone, with a key of its own, because a reader needed its target. The general
  fix is to keep every argument, so that no annotation needs a key of its own just to keep its
  argument.

## The shape

Each entry of `annotations` is what the tools already decode (`Annotation.fromJson`):

- an annotation **without** an argument stays a string: `"owner"`, `"res.optional"`;
- one **with** an argument becomes `{"name": "storageRef", "args": "\"Catalog.productImages\""}`,
  with `args` the source between the parentheses, as written.

A field whose annotations take no argument is therefore written exactly as today, byte for byte.
In the hybrid example only the five fields above change.

`ref` stays as it is: `annotations` then holds `{"name": "ref", "args": "\"AvailableProducts\""}`,
and the parsed target stays in `ref` beside it.

## S1 — Emit the argument

- **One way to cut an argument.** `SourceReader.attribute_json` already computes an attribute's
  argument text: from its payload's first item to its last, cut from the source by
  `byte_offset`, so it is right after non-ASCII text on the same line. Move that into
  `SidecarEmit` as `attribute_args ~src a : string option`. The reader then calls it from there,
  as it already calls `SidecarEmit`'s test and marker helpers, so the reader and the sidecar
  cannot disagree about what an argument is.
- **The source reaches `field_json`.** `write_sidecar` (`:343`) reads the file once with
  `read_source` (`:385`, which the GWT sidecar already uses) and passes `?src` through
  `fragment_json` to `field_json`, including for nested records (`:250`).
- **`annotation_json ?src a`** writes a string when the attribute has no payload, or when `src`
  is `None` (the file could not be read: the name alone, as today, rather than no entry).
  Otherwise it writes `{"name", "args"}`. `attr_names` goes, and `field_json` maps
  `annotation_json`.
- **`res.*` stays names only.** These are the parser's printing hints, not authored annotations
  (`SourceReader.is_authored`), and `res.doc`'s payload is a whole doc comment. Keeping them
  names-only also keeps `res.optional` a plain string, which is the one annotation today's
  readers act on.
- **Only a structure payload has args.** `@attr(expr)` is `PStr`. The rare `PTyp` / `PPat` /
  `PSig` payload shapes stay names only, and the test pins that.
- **The body is still the one from before the transforms,** `raw_spec_body`
  (`ReventlessPpx.ml:815`), so the DCB passes' stripping of annotations does not reach the
  sidecar. This does not change.

### Tests

- `test_sidecar.ml`: `fragment_json` takes `~src`. Cases:
  - a bare `@owner` is the string `"owner"`;
  - `@storageRef("Catalog.images")` is `{name, args: "\"Catalog.images\""}`;
  - `@authorize(AllowGroups(["Admin", "Merchandiser"]))`, an argument with spaces, brackets and
    commas, round-trips exactly;
  - `@default(1)`;
  - a field after `—` on the same line gets the right argument;
  - `res.optional` stays a string;
  - with no `src`, every entry is its name, as today.
- `test/run.sh`, the "sidecars over real ReScript source" fixture (`:3976`): a spec with
  `@storageRef(…)` compiles and its `.model.json` holds the argument. A spec without arguments
  is byte-identical to the sidecar the previous PPX wrote. Keep that file as a golden.
- The hybrid example's sidecars, rebuilt: only the five fields above change.

### Docs

`docs/guides/reverse-codegen-pipeline.md`: an `annotations` entry is a name, or `{name, args}`
when the annotation has an argument; `res.*` are always names.

### Outcome

- `SidecarEmit.attribute_args_span` / `attribute_args` is the one cutter; `SourceReader.attribute_json`
  calls it. `read_source` and `byte_offset` moved above the field walk so it can.
- The `.types.json` sidecar writes its fields through the same `field_json`, so it gets the source
  too and keeps arguments the same way.
- The golden is `test/golden/RegisterShelf.model.golden.json` (a `*.model.json` name is git-ignored).
- The hybrid example's 41 sidecars, rebuilt: only the five fields named above changed.

## S2 — Release

The PPX release procedure, as in [gwt-sidecar-refs-and-examples.md](gwt-sidecar-refs-and-examples.md)
R3. **Exit:** the published PPX writes arguments. The companion phase then closes its upstream
item, and reventless-tools raises its PPX floor to this version wherever it emits from a
sidecar-assembled model.

## Risks

- **A reader that expects strings only.** reventless-tools before its Phase 3 decodes
  `annotations` with a filter that keeps strings, so it drops an object entry. The only
  annotation those versions act on is `res.optional`, which stays a string, so nothing they do
  changes. Nothing in core reads the sidecar's `annotations`.
- **The argument is source text, not a value.** `"\"Catalog.images\""` includes its quotes, and
  `AllowGroups([...])` is an expression. That is intended: a reader writes it back as it came.
  A reader that wants the value parses it, as `ReferenceInference` does for `@ref`, and should
  get a key of its own, as `ref` did.
- **Two cutters drift.** This is why S1 moves the reader's cutter into `SidecarEmit` rather than
  writing a second one.

## Not in scope

- **Type-level attributes** (`@schema @namedWhenRetired type state`) and **constructor
  attributes.** The model sidecar has no place for either today. The tools read them from source
  with `spec-read`.
- **Parsing arguments into values.** Only a key a reader needs (`ref`) gets that.
