# Plan: the GWT sidecar keeps named values and code, and example files get a sidecar

**Status:** 🚧 R1 and R2 built — 2026-09-22, with the guide and the `.gitignore` entry. Not yet
released (R3).<br/>
**Touches:** `packages/reventless-ppx` only (`src/ppx/SidecarEmit.ml`, `src/ppx/ReventlessPpx.ml`,
`src/test_sidecar/`), the root `.gitignore`, and `docs/guides/reverse-codegen-pipeline.md`.<br/>
**Companion:** reventless-tools `docs/plans/scenario-example-data.md`, phase E4, where the
scenario form writes named example values into example files and the codegen reverse pass
reads them back.

## Goal

Every field value a GWT scenario states reaches the `.gwt.json` sidecar. A value the PPX can
read as a literal is recorded as today. A named value (`dockLine`) is recorded as a reference
to that name. Anything else (`eur(4500.0)`) is recorded as its source text. And a file of
named example values (`@@reventless.examples`) gets a sidecar of its own, so a reader can
resolve those references without parsing ReScript.

## Why

`example_of_expr` in `SidecarEmit.ml` records literals only: strings, numbers, booleans,
`None`/`Some`, a typed id made from one string literal (`oid("o1")`), payload-less
constructors, arrays and records. Every other expression returns `None`, and the field is
**dropped** from the sidecar without a trace. In `examples/online-shop-hybrid/ordering`'s
`Orders_GWT.res`:

```rescript
lines: [dockLine, chargerLine],   // sidecar: {"kind":"list","items":[]}
total: eur(4500.0),               // sidecar: field missing
```

A reader cannot tell a field the test leaves out from one the PPX could not read. The reverse
pass then writes back an Event Model in which those fields are empty or absent, and a forward
pass from that model would lose them from the test. The scenario form in the companion plan
makes this common: it writes named example values and refers to them by name.

## Scope

**In:** the example values of the `.gwt.json` sidecar, a new `.examples.json` sidecar, the
`@@reventless.examples` attribute, the guide that documents the sidecars.

**Out:**
- The `.model.json` sidecar. Its fields carry no example values.
- Resolving a reference. The sidecar records the name as written; the reader decides what it
  points to.
- Evaluating code. `code` is text, not a value.
- Everything in reventless-tools, which is the companion plan.

## Phases

### R1 — References and code in the GWT sidecar

- A bare value identifier (`Pexp_ident`, `Lident` or `Ldot`) becomes
  `{"kind":"ref","name":"<the flattened name>"}`: `o1` gives `"o1"`,
  `OrderingExamples.dockLine` gives `"OrderingExamples.dockLine"`.
- Any other expression `example_of_expr` cannot read becomes
  `{"kind":"code","value":"<the exact source text of the expression>"}` instead of `None`.
  - The text is cut from the `.res` file by the expression's location
    (`pexp_loc.loc_start.pos_cnum` to `loc_end.pos_cnum`). The file is read once per sidecar;
    the scenario-id markers are read from the same text.
  - When the text cannot be obtained (no file, offsets out of range, a location the parser did
    not set), the field is dropped as today.
  - The text is never printed from the AST: `Pprintast` prints OCaml syntax, not ReScript.
- Literal handling is unchanged. `Some(x)` still records `x`'s value, so `Some(o1)` is a ref.
- References and code appear wherever a value does: a record field, an array item, a step's
  values.
- `test_sidecar.ml`: a ref for a bare and a qualified identifier; a ref inside `Some(...)`, an
  array and a record field; code with the exact text for
  `Reventless.Money.make(~amount=1000.0, ~currency=Reventless.Currency.EUR)`; a record field
  holding such a call is present; the literal cases keep their output.
- **Behaviour change, stated in the changelog:** fields that were missing from the sidecar are
  now present, as `ref` or `code`, and a list of named values is no longer empty. The consumer
  (reventless-tools codegen, `Model.exampleValueFromJson`) already decodes `code`; `ref` is new
  to it, and the companion plan adds it.

### R2 — The example-file sidecar

- A file carrying `@@reventless.examples` gets `<Stem>.examples.json` next to the source,
  under the same conditions as `.gwt.json` (`REVENTLESS_EMIT_SIDECAR=1`, best effort, never
  failing the compile):

  ```json
  {
    "module": "OrderingExamples",
    "file": "examples/online-shop-hybrid/ordering/src/OrderingExamples.res",
    "examples": [
      {
        "name": "dockLine",
        "type": "orderLine",
        "kind": {"kind": "custom", "name": "orderLine"},
        "line": 3,
        "value": {"kind": "record", "entries": [...]}
      }
    ]
  }
  ```

  - `module` is the file stem; `file` is repo-root-relative, as in the other sidecars.
  - `type` is the annotation as written (`OrderId.t`, `array<orderLine>`), or `""` when the
    binding has none.
  - `kind` is the field kind `kind_of_type` gives a spec field; an unannotated binding gets
    `{"kind":"custom","name":"Unknown"}`.
  - `line` is the 1-based line of the `let`.
  - `value` is `example_of_expr`'s value, R1's `ref` and `code` included.
- Only top-level `let` bindings of a single name count, with or without a type annotation.
  Every other item (a type, a module, a destructuring `let`, an expression) is ignored.
- The attribute is removed before any other pass, the way the other file-level
  `@@reventless.*` attributes are consumed. It selects no mode: the file is otherwise compiled
  unchanged, with nothing included or opened.
- `*.examples.json` is git-ignored beside `*.gwt.json`.
- `docs/guides/reverse-codegen-pipeline.md` names the `.examples.json` sidecar and the `ref`
  and `code` values.
- `test_sidecar.ml`: an annotated `let`, an unannotated `let`, a `let` whose value is a ref, and
  a non-`let` item that is ignored. `test/run.sh` compiles a ReScript example file and a GWT file
  with `REVENTLESS_EMIT_SIDECAR=1`, so the code text is checked against ReScript source, not
  only the OCaml syntax the unit test parses.

### R3 — Release

- Follows the PPX release procedure: build the binary, stage it locally over the installed
  per-platform package, remove every workspace `lib/` (never `rescript clean` over the
  examples), run the full root build, `packages/reventless-ppx/test/run.sh` (it is not in the
  root chain) and the root `pnpm test`. CI publishes the binary and resolves the version; do
  not bump it by hand.
- **Exit:** the published PPX writes `ref` and `code` values and the `.examples.json`
  sidecar. The companion plan's E4 may rely on them.

## What R1 and R2 found

- `examples/online-shop-hybrid/ordering` built with `REVENTLESS_EMIT_SIDECAR=1`: its 20 GWT
  sidecars carry 121 code values and 39 refs, and every code value occurs verbatim in its
  `.res` file. The ReScript parser's offsets cut expressions exactly, including labelled
  arguments, template strings and nested calls.
- A function binding in an example file (`let eur = amount => …`) gets no entry. The lambda
  reaches the PPX wrapped in a node without a usable location, so there is no text to cut, and
  the entry is dropped as a value without text is. A helper is not an example value, so this
  is left as it is.
- `-5` is an `int` literal, as ReScript parses it into the constant.

## Verification

- `packages/reventless-ppx/test/run.sh` and the sidecar unit test pass.
- `examples/online-shop-hybrid/ordering` built with `REVENTLESS_EMIT_SIDECAR=1`, with a scratch
  file added to its `tests/` and removed afterwards:
  - `Orders_GWT.gwt.json` records `lines` as two refs (`dockLine`, `chargerLine`) and `total`
    as code `eur(4500.0)`, where before `lines` was an empty list and `total` was missing;
  - a scratch `OrderingExamples.res` carrying `@@reventless.examples` compiles and gets its
    `.examples.json`.

## Risks

- **A consumer that does not know `ref` meets one.** Released codegen decodes example values
  strictly by kind. It must learn `ref` before it reads sidecars from this PPX; the companion
  plan does that in the same step that starts writing named values.
- **A location that does not match the source.** A value built by another pass, or by parser
  sugar, may carry a location whose text is not the value. Offsets outside the file are
  rejected; the rest is checked on the examples' GWT corpus, where every code value read back
  is the expression as written.
- **Code text is not portable.** `eur(4500.0)` means something only where `eur` is in scope.
  The sidecar records it as written, which is what a writer needs to put it back.
