# vscode-protocol: shared D2 renderer for the protocol graph (`DomainGraphD2`)

**Status:** Implemented 2026-07-07 (uncommitted) — package build + 174 tests green, `check:d2-styles` in sync; needs commit + `alpha.17` publish for downstream consumers
**Owner:** Martin
**Follows:** GraphOps move into this package (focus/neighbourhood scoping, `eab1bfd2d`) — same argument, same playbook.

## Motivation

The reventless-vscode extension renders the Event-Modeling graph by translating the
protocol graph model (`Protocol.graphNode`/`graphEdge`) into D2 source — a pure
function (`toD2`) over exactly the types this package owns. Like `GraphOps` before
it, that renderer is (a) pure, (b) typed entirely against the protocol vocabulary,
and (c) wanted by more than one consumer: the extension shells the output to the
`d2` CLI, while a web console can rasterize the same output with D2's WASM build in
the browser. Keeping the renderer in one consumer forks the pixels the moment a
second consumer draws the same graph.

**Boundary check (dev-time-open):** `toD2` renders *any* protocol graph handed to
it — it contains no acquisition, no derivation, no deployed-platform logic. It is
presentation over the open protocol model, so it belongs in the open package next
to `GraphOps`.

## Scope — modules moving in (from the extension)

| Module | Role | genType surface |
|---|---|---|
| `DomainGraphD2.res` | `toD2` + `nodeClassOf`/`edgeClassOf`/`legend`/`presentKeys`/`applyLegendFilter` | `subgraph` type + the exported functions |
| `D2Classes.res` | GENERATED semantic class block + shape colours + legend swatches | none |
| `D2Legend.res` | shared `legendEntry` shape + entry constructors | `legendEntry` type |
| `D2Emit.res` | D2 string escaping (`q`/`qLabel`) | none |
| `D2Shapes.res` | extension-point/extension SVG icons (socket/plug) | none |
| `scripts/d2-classes-gen.mjs` | regenerates `D2Classes.res` from the canonical palette | — |

The canonical palette (`packages/doc/d2/reventless.d2`) already lives in THIS repo —
the generator's cross-repo soft-skip becomes a same-repo hard requirement, and the
palette → tooling sync stops crossing a repo boundary entirely.

## Steps

1. Copy the five `.res` modules into `src/` (drop the `ReventlessVscodeProtocol.*`
   self-aliases — they're siblings now), move the generator to `scripts/` with the
   same-repo canonical path, regenerate `D2Classes.res`.
2. **Browser portability:** `D2Shapes.base64` used Node's `Buffer` — replace with an
   environment-agnostic base64 (`Buffer` when present, `TextEncoder`+`btoa`
   otherwise) so WASM/browser consumers can call `toD2` unchanged.
3. Extend BOTH hand-written genType bridges (package root + `src/`) with the
   `DomainGraphD2_*` and `D2Legend_*` type re-exports; extend `BridgeDriftTest`'s
   `generatedModules` accordingly.
4. Port `DomainGraphD2Test.res` and `D2ClassesGenTest.res` into `tests/` (jest /
   rescript-jest idiom; the d2-binary smoke test keeps its skip-when-absent guard).
5. Add `sync:d2-styles` / `check:d2-styles` package scripts.
6. Consumer side (extension repo): delete the local copies, import
   `.../src/DomainGraphD2.gen` like GraphOps — move, not copy.

## Follow-up (same wave, 2026-07-07)

`toD2` gained two opt-in override hooks for comparison overlays: `~nodeClass`
(nodeId → class, replacing the kind-derived palette class) and `~edgeClass`
((from, to, class), overriding the connection class per endpoint pair), plus four
generator-authored palette classes (`drift-added`/`drift-removed` for shapes,
`*-flow` twins for connections — d2 rejects `fill` on connections). Generic
presentation hooks; what a consumer diffs to produce the overrides stays outside
this package.

## Acceptance

- `rescript build` + `pnpm test` green in the package; `check:d2-styles` in sync.
- Every generated `export type` re-exported by both bridges (BridgeDriftTest).
- `toD2` output byte-identical to the pre-move extension renderer for the same
  inputs (the ported golden tests pin this).
- No Node-only globals on the `toD2` path.
