# Plan: a source reader that says where each declaration sits in a file

**Status:** 📋 Planned — 2026-09-22. Nothing built. S0 (the spike) comes first and decides
whether S1–S3 are built.<br/>
**Touches:** `packages/reventless-ppx` only: a second executable beside `bin`, sharing the
`ReventlessPpx` library.<br/>
**Companion:** reventless-tools `docs/plans/forms-as-views-of-the-source.md` (its L4), where the
authoring forms open existing slices, views and scenarios from their source and edit them in
place. Its analysis is reventless-tools `docs/analysis/forms-as-views-of-the-source.md`.

## Goal

One command reads one ReScript file and prints its declarations as JSON, each with its **span**
(start and end offset in the file). Declarations are types, variant cases, record fields,
attributes with their arguments, and the GWT chains of a `@@reventless.gwt` file. It reads
exactly as the compiler does, needs no build, and runs in milliseconds per file.

## Why

Tools that edit ReScript source in place need to know where each thing is, so that a change
replaces one span and leaves everything around it (comments, helpers, formatting) as written.
Today the tooling reads source with hand-written scanners, and each one covers only the shapes
someone thought of: multi-line variant payloads, strings and comments are known gaps.

The PPX sidecars (`.model.json`, `.gwt.json`) are no substitute, for three reasons:
- They carry no spans for declarations. Only a test's start line is recorded (`SidecarEmit.ml`).
- They drop values: a list of named values becomes empty, a helper call such as `eur(4500.0)`
  is dropped, and the row key of `thenStateWithId` is missing.
- They are written only under `REVENTLESS_EMIT_SIDECAR=1`, in a clean build.

The reader belongs here because the PPX already works on this parse tree, and because which
attributes exist, and which arguments they take, is decided here. A reader elsewhere would be a
second copy of both.

## The approach

The compiler already writes the parse tree of one file without building anything:

```sh
bsc -bs-ast -o PlaceOrder.ast PlaceOrder.res   # 6 ms on examples/online-shop-hybrid's PlaceOrder.res
```

That binary AST is the input the PPX already reads on every compile, with locations. The
reader is a second executable in this package. It reads the `.ast` file with the same ppxlib
machinery, walks it, and prints JSON. **Parsing stays the compiler's.** This package adds only
the walk and the output.

Comments are not in the parse tree. That is acceptable: with spans, an edit replaces only the
member it changes, so comments outside that member are never touched. Doc comments (`/** */`)
arrive as `res.doc` attributes and are reported like any other attribute.

## Phases

### S0 — Spike ⏱ ≤1 day

- A throwaway executable reads `.ast` output of `bsc -bs-ast` and prints, for every type
  declaration, its cases and fields, their attributes, and each one's span.
- Run it over every `@@reventless.spec` file in `examples/online-shop-hybrid`.
- **Answers it must give:**
  1. Do the spans cut out exactly the member's source text (byte offsets, including multi-line
     payloads, optional `?` fields and attributes with arguments)?
  2. Is the whole round trip (bsc, then the reader) under ~50 ms per file?
  3. Does the `.ast` format match between the `bsc` the tooling ships and the ppxlib version
     this package builds against, or does the reader need the same version guard the PPX has?
- **Exit:** a written verdict at the end of this file. If it fails, the companion plan falls
  back to its hand scanners, and this plan is closed as rejected with the reason.

### S1 — The reader for spec files

- `reventless-ppx-read <file.res>` runs `bsc -bs-ast` itself (the path to `bsc` given by the
  caller or found beside `rescript`) and prints JSON:
  - each type: name, kind (record, variant, alias), span, attributes;
  - each case: name, payload fields or positional types, span;
  - each field: name, optional, type text, span, attributes;
  - each attribute: name, argument source text, span.
- The type text is the source slice of the type expression, not a printed form, so the caller
  sees what was written.
- **The walk and the attribute list come from the `ReventlessPpx` library**, so a new attribute
  in the PPX appears in the reader without a second change.
- **Exit:** a test over every spec file of the hybrid example: every span, cut from the file, is
  exactly the member's source.

### S2 — GWT files and behaviour outlines

- For a `@@reventless.gwt` file: each `test(...)` with its title, span, scenario id marker (if
  any), and the chain's steps (`given…`, `when…`, `then…`). Each step has its element and its
  field values **as source text with spans**, never evaluated.
- For a projection: each case of `project` with its event, effect (`Set`, `Update`, `Delete`),
  key expression and span.
- For a spec's `commandTransition`: each arm with its command, from states, to state and span.
- **Exit:** every GWT test in the hybrid example is reported with its steps. The values that the
  `.gwt.json` sidecar drops (`lines: [dockLine, chargerLine]`, `total: eur(4500.0)`) are
  present, as source text.

### S3 — Release

- Built and published with the PPX binary, per the PPX release procedure (rebuilt binary,
  `test/run.sh`, one commit, CI resolves the version).
- **Exit:** the published package contains the reader for every platform the PPX ships for.

## Not in scope

- **Writing source.** Callers replace spans and run `rescript format`. The reader never edits.
- **Type checking.** The reader parses only. It knows what a field's type says, not what it
  resolves to.
- **Comments as data.** They stay out of the parse tree. If a caller ever needs them, that is a
  separate decision.

## Verdict (S0)

_Not run yet._
