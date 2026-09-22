# Plan: a source reader that says where each declaration sits in a file

**Status:** 🚧 2026-09-22 — S0 passed (verdict below: the reader runs as a ppx under bsc). S1,
S2's GWT tests and top-level `let`s, and S3 released in the PPX 1.0.0-alpha.87. S2's projection
and transition outlines are not built (see "What was built").<br/>
**Touches:** `packages/reventless-ppx` only: a second executable beside `bin`, sharing the
`ReventlessPpx` library.<br/>
**Companion:** reventless-tools `docs/plans/forms-as-views-of-the-source.md` (its L4), where the
authoring forms open existing slices, views and scenarios from their source and edit them in
place. Its analysis is reventless-tools `docs/analysis/forms-as-views-of-the-source.md`. Also
reventless-tools `docs/plans/scenario-examples-adoption.md` (its M1), which migrates the example
apps' GWT tests to named examples by replacing spans.

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

- `reventless-ppx-read <file.res>` runs `bsc -ppx <itself> -bs-ast` (the path to `bsc` given
  by the caller or found beside `rescript`; see the S0 verdict) and prints JSON:
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
- For any file, each top-level `let`: its name, span, the span of its body, and for a function
  its parameters (label, default's source text). This covers a GWT file's helpers
  (`let pid = CatalogSpec.ProductId.make`, `let eur = amount => …`) and builders
  (`let synced = (~id, ~name, ~price=2500.0) => CatalogProductSynced({…})`), which a tool
  migrating hand-written tests to named examples resolves and inlines.
- **Exit:** every GWT test in the hybrid example is reported with its steps. The values that the
  `.gwt.json` sidecar drops (`lines: [dockLine, chargerLine]`, `total: eur(4500.0)`) are
  present, as source text. Every top-level `let` of `PlaceOrder_GWT.res` is reported, and its
  span cuts exactly the binding.

### S3 — Release

- Built and published with the PPX binary, per the PPX release procedure (rebuilt binary,
  `test/run.sh`, one commit, CI resolves the version).
- **Exit:** the published package contains the reader for every platform the PPX ships for.

## What was built (2026-09-22)

- **`src/ppx/SourceReader.ml`** (in the `ReventlessPpx` library) walks the tree. It reuses
  `SidecarEmit`'s test and marker helpers (`describe_of_item`, `scenario_id_for`, the step
  verbs), so the reader and the `.gwt.json` sidecar find the same tests and the same ids.
- **`src/read/read.ml`** is the executable (`read.exe`, shipped as `reventless-ppx-read` through
  the `read` launcher). Run as a command it runs bsc with itself as the ppx; run by bsc it
  writes the JSON and passes the tree through. bsc is taken from `--bsc`, `RESCRIPT_BSC_EXE`, or
  the nearest `node_modules/@rescript/<platform>/bin/bsc.exe` above the file. A file bsc cannot
  parse exits 1 with bsc's message.
- **Output.** `{file, attributes, opens, types, lets, describes}`. Every node has `span`
  (`{start, end}`, byte offsets) and `text` (the source that span cuts).
  - A type has `name`, `kind` (`variant` / `record` / `alias` / `abstract` / `open`),
    `attributes`, and `cases` or `fields` (or an alias's `manifest`). A case has `fields` or
    positional `args`. A field has `name`, `optional`, `mutable`, `type` and `attributes`. An
    attribute has `name` and `args` (its argument's source, or null). Printing hints the parser
    adds (`res.*`) are left out, except doc comments (`res.doc`).
  - A `let` has `name`, `recursive`, `type` (an annotation, or null) and `value`.
  - A value is an outline: `string`, `int`, `float`, `ident`, `constructor` (with `payload`),
    `record` (`fields`, each with its own span, and `spread`), `array`, `call` (`fn`, `args` with
    their labels), `constraint`, `function` (`params` with label and `default`, `returnType`,
    `body`), or `other`.
  - A describe has `describe` and `tests`; a test has `title`, `scenarioId` (or null) and
    `steps`, each a `verb` and the values it is given. A step is any `given…` / `when…` /
    `then…` call, not only the verbs the sidecar reads, so a translation's
    `whenIncomingEvent` / `thenPublishesCommand` are reported; `->thenNoEvent` is a step with
    no values.
- **Tests** (`test/run.sh`, new last section, via `test/reader-spans.mjs`):
  - the 52 spec files of the hybrid example, 2133 spans, each cutting exactly its declaration;
  - the 79 GWT files, 442 tests, each test that calls a step read with its steps (a test that
    asserts without a chain, as `NotificationIntake_GWT.res`'s table checks do, has none);
  - `Orders_GWT.res`'s `lines: [dockLine, chargerLine]` and `total: eur(4500.0)`;
  - `PlaceOrder_GWT.res`'s 9 top-level `let`s, and `synced`'s parameters and default;
  - a scenario-id marker, a test without one, `->thenNoEvent`, and a file that does not parse.
  - Warm, a file takes about 20 ms.
- **Packaging (S3).** `publish-ppx.yml` stages `read.exe` beside `ppx.exe` in each platform
  package, and its drift guard runs the reader section against the published `read.exe`
  (`REVENTLESS_PPX_READ_BIN`). `scripts/publish-ppx-local.mjs` stages it too.
  - Released in 1.0.0-alpha.87. Its first drift-guard run gave up waiting for the linux-x64
    tarball, which the registry served about 8 minutes after publishing; a rerun passed (386
    checks, the reader's included). The drift guard's and the relock's retry windows are now
    10 minutes.
- **Fixed 2026-09-22 (after alpha.87): a negative constant's span.** The parser folds a
  minus into the constant (`-2` is `Pconst_integer "-2"`) but keeps the location of the
  digits, so the span cut `2`, and `-.3.5` cut `3.5`. The value was right. A tool inlining a
  builder call by span (`line(~id="p1", ~qty=-2)`) wrote `quantity: 2`, and a test of a
  negative quantity then placed an order. `constant_loc` now starts such a span at its `-`
  (or `-.`), over any space between; a subtraction (`3 - 1`) is a call and unaffected.
  `test/run.sh` checks both.
- **Fixed 2026-09-22 (after alpha.88): spans after non-ASCII text on the same line.** The
  parser gives a position's line start (`pos_bol`) in bytes but counts its column in UTF-16
  code units, so on a line holding `"Thanks — we have your order"` every later position fell
  short of its byte: by one for `é`, two for `—` or an emoji. A tool replacing that string by
  its span left `."` behind. `SidecarEmit.byte_offset` walks the column over the line's bytes;
  the reader and the `.gwt.json` sidecar's `code` values both go through it. S0's check
  missed this because no spec file has a non-ASCII string. `test/reader-spans.mjs` now checks
  every value node of every GWT file of the hybrid example (7240: a string its quotes, a
  number its value, a name itself, a constructor from its name), and `test/run.sh` a line with
  `—`, an emoji and an accented comment.
- **Not built yet (rest of S2):** a projection's `project` cases and a spec's
  `commandTransition` arms. The GWT migration does not need them; the forms-as-views work does,
  and adds them when it starts.

## Not in scope

- **Writing source.** Callers replace spans and run `rescript format`. The reader never edits.
- **Type checking.** The reader parses only. It knows what a field's type says, not what it
  resolves to.
- **Comments as data.** They stay out of the parse tree. If a caller ever needs them, that is a
  separate decision.

## Verdict (S0) — 2026-09-22: passes, with a different way in

A throwaway executable on ppxlib 0.34 and `bsc` 12 from the workspace, run over the 52
`@@reventless.spec` files of `examples/online-shop-hybrid` and over `PlaceOrder_GWT.res`.

1. **Spans: exact.** 2133 spans checked (types, cases, fields, field types, attributes), none
   wrong. A case's span runs from its `|` to its closing `})`, comments inside included. A
   field's span includes its attributes and the `?` of an optional field (which the tree
   carries as a `res.optional` attribute with an empty location). A type's span starts at
   `type`; its own attributes (`@schema`) sit before it. Every top-level `let` of
   `PlaceOrder_GWT.res` cuts exactly: the aliases, the money helpers, and the multi-line
   builders, whose labelled parameters and defaults (`~price=2500.0`) each have their own span.
   **One exception:** an attribute's location covers its name only (`@ref`, not
   `@ref("AvailableProducts")`). The reader reports an attribute's span from its location's
   start to its payload's end.
2. **Timing: 11 ms median per file,** bsc and the reader together; under 100 ms on a cold
   first run.
3. **Format: `-bs-ast` cannot be read directly.** That file is bsc's own marshalled tree (a
   dependency list, the source path, then the compiler's current parse tree), not the
   OCaml-magic binary AST that ppxlib reads. bsc converts to that format only when it hands the
   tree to a ppx. **So the reader runs as a ppx:** `bsc -ppx <reader> -bs-ast -o <scratch> <file>`.
   bsc parses and converts; the reader reads the tree, writes its JSON, and passes the tree
   through unchanged. This is the conversion the PPX relies on for every compile, so the reader
   needs no version guard of its own.

**Consequences for S1:** the reader is invoked through bsc as above (the caller gives the path
to `bsc`, or it is found beside `rescript`), and reports attribute spans as described in 1.
S1–S3 go ahead.
