# ReScript Code Intelligence for Claude Code

Source: [code-graph-analysis.md](../analysis/code-graph-analysis.md)

This plan adds ReScript code intelligence to the Claude Code development workflow in three independent steps, ordered by value-to-effort ratio.

---

## Step 1: Claude Code LSP Plugin for ReScript ✅

**Goal:** Give Claude Code type-aware ReScript navigation (go-to-definition, find-references, hover, diagnostics) by configuring `@rescript/language-server` as a Claude Code LSP plugin.

**Effort:** Days

**Why first:** The LSP already exists and is production-quality. This provides compiler-level intelligence (types, cross-file resolution) — strictly more powerful than syntax-only tools. The existing `workshop:typescript-lsp` skill serves as a template.

### Implementation

Created an LSP plugin at `~/.claude/plugins/marketplaces/claude-code-lsps/rescript-lsp/` following the same structure as the 22 existing language plugins (ocaml-lsp, vtsls, etc.):

```
rescript-lsp/
├── .claude-plugin/
│   └── plugin.json          # Plugin metadata
├── .lsp.json                # LSP config: maps .res/.resi → rescript language ID
└── hooks/
    ├── hooks.json           # SessionStart hook for auto-install check
    ├── check-rescript-lsp.sh  # Checks global install
    └── rescript-lsp.sh      # (legacy, no longer used)
```

**Key design decisions:**
- Uses globally installed `rescript-language-server` binary directly (matching the pattern of all other working plugins)
- Language ID registered as `"rescript"` for both `.res` and `.resi` files
- Prerequisite: `npm install -g @rescript/language-server`

### Debugging History (2026-03-12)

**Problem:** Claude Code reported `"No LSP server available for file type: .res"` despite the plugin being in the correct directory alongside 22 working plugins.

**Investigation findings:**
1. The LSP binary works correctly — manual testing with LSP protocol messages produces valid `initialize` responses with full capabilities (definition, references, hover, documentSymbol, completion, rename, etc.)
2. The original `.lsp.json` used `"command": "bash"` with a launcher script as args. **Every other working plugin** uses a direct binary command (e.g., `"command": "pyright-langserver"`). The only exception is `sourcekit-lsp` which uses `"command": "xcrun"` — also a direct binary, just an indirect invocation.
3. The launcher script (`rescript-lsp.sh`) tried to find a VS Code extension path first, falling back to `npx`. The VS Code extension is not installed, and `npx` had issues with stdio piping (exit 127 in some contexts).

**Fix applied:**
1. Installed `@rescript/language-server` globally: `npm install -g @rescript/language-server` → `rescript-language-server` binary in PATH (v1.72.0)
2. Changed `.lsp.json` from bash wrapper to direct binary: `"command": "rescript-language-server", "args": ["--stdio"]`
3. Simplified `check-rescript-lsp.sh` to use `command -v rescript-language-server`

**Next:** Restart Claude Code session to verify plugin loads correctly.

### Tasks

- [x] 1.1 — Research Claude Code LSP plugin configuration format (`.lsp.json` + `.claude-plugin/plugin.json` + hooks)
- [x] 1.2 — Verify `@rescript/language-server` is available (v1.72.0 works with `--stdio`, responds to LSP initialize)
- [x] 1.3 — Create LSP plugin in `~/.claude/plugins/marketplaces/claude-code-lsps/rescript-lsp/`
- [x] 1.4 — Configure file pattern matching for `.res` and `.resi` extensions
- [x] 1.5 — Debug plugin loading: identified bash wrapper as the issue, switched to direct binary command
- [x] 1.6 — Restart session and verify plugin loads (test go-to-definition, find-references, hover, document-symbols)
- [x] 1.7 — Auto-diagnostics: not directly testable via LSP tool (no diagnostics operation), but the LSP server supports `textDocument/publishDiagnostics` — diagnostics fire automatically on file edits
- [x] 1.8 — Documented in CLAUDE.md under "ReScript LSP" section

### Acceptance Criteria

- Claude Code can resolve ReScript symbols (definitions, references) via LSP instead of grep
- Diagnostics surface ReScript compiler errors after edits
- No regression in TypeScript LSP behavior

---

## Step 2: ast-grep Custom Language for ReScript ✅

**Goal:** Enable structural code search and refactoring for ReScript files using ast-grep with tree-sitter-rescript.

**Effort:** Hours

**Why second:** Very low effort — just compile the existing tree-sitter grammar and register it. Useful for pattern-based searches like "find all functor applications" or "find all `@module` externals" that regex handles poorly.

### Implementation

- Installed `@ast-grep/cli` v0.41.1 globally via npm
- Cloned `rescript-lang/tree-sitter-rescript` and compiled `rescript.dylib` with Apple clang
- Created `sgconfig.yml` at repo root with `expandoChar: _` (since `$` is not valid ReScript syntax)
- Added `rescript.dylib` to `.gitignore`; `sgconfig.yml` committed to repo

**Metavariable syntax:** Use `_NAME` (single match) and `___` (multi-match) instead of `$NAME`/`$$$`.

### Working Patterns

| Pattern | Finds |
|---------|-------|
| `type _NAME` | All type declarations |
| `module type _NAME = { ___ }` | Module type signatures |
| `let _FN = async (_ARGS) => { ___ }` | Async function definitions |
| `Obj.magic(_ARG)` | All Obj.magic calls (type-unsafe code) |
| `_X->Array.map(_FN)` | Pipe chains to specific function |
| `___->ignore` | All ignored expressions (code smell) |

**Known limitations:**
- `open _MODULE` / `include _MODULE` don't parse — tree-sitter-rescript wraps these in a statement node that doesn't match the pattern. Use grep for these.
- `@module(...)` external declarations parse as multiple AST nodes — not matchable as a single pattern.
- Patterns containing `let` at top level produce ERROR nodes but still match correctly.

### Rebuild instructions

```bash
git clone https://github.com/rescript-lang/tree-sitter-rescript.git /tmp/tree-sitter-rescript
gcc -shared -fPIC -O2 -I /tmp/tree-sitter-rescript/src \
  -o rescript.dylib \
  /tmp/tree-sitter-rescript/src/parser.c /tmp/tree-sitter-rescript/src/scanner.c
```

### Tasks

- [x] 2.1 — Install ast-grep CLI (`npm i -g @ast-grep/cli` → v0.41.1)
- [x] 2.2 — Compile tree-sitter-rescript as a dynamic library (`gcc -shared` → `rescript.dylib`)
- [x] 2.3 — Create `sgconfig.yml` at repo root with `expandoChar: _`
- [x] 2.4 — Test structural searches (type declarations, module types, async functions, Obj.magic calls)
- [x] 2.5 — Document working patterns and limitations in this plan
- [x] 2.6 — Added `rescript.dylib` to `.gitignore`; `sgconfig.yml` committed

### Acceptance Criteria

- ✅ `sg` can search ReScript files by AST pattern (modules, let bindings, type declarations)
- ✅ 6 useful ReScript patterns documented

---

## Step 3: CodeGraph ReScript Support (Upstream Contribution) ✅

**Goal:** Add ReScript language support to `@colbymchenry/codegraph` so the MCP-based code graph includes ReScript symbols and relationships.

**Effort:** Days (revised down — CodeGraph uses declarative TypeScript extractors, not `.scm` query files)

**Why third:** Provides token reduction (~30%) and richer context for Claude Code.

### Architecture (corrected from initial plan)

CodeGraph does **not** use `.scm` query files. Instead, each language provides a `LanguageExtractor` object in `src/extraction/tree-sitter.ts` mapping AST node types to graph concepts (`functionTypes`, `classTypes`, `importTypes`, `callTypes`, etc.).

Languages not in the `tree-sitter-wasms` npm package ship their own `.wasm` in `src/extraction/wasm/` (like Pascal).

### ReScript AST → CodeGraph Node Mapping

| CodeGraph concept | ReScript AST node type | Notes |
|---|---|---|
| function | `let_declaration` (when body is `function`) | let bindings with function bodies |
| function | `external_declaration` | FFI bindings |
| module (→ namespace) | `module_declaration` | Primary organizational unit |
| interface | `module_declaration` (with signature, no definition) | Module types |
| type_alias | `type_declaration` | All type declarations |
| enum | `type_declaration` (with `variant_declaration` body) | Variant types |
| struct | `type_declaration` (with `record_type` body) | Record types |
| import | `open_statement` | `open Module` |
| import | `include_statement` | `include Module` |
| calls | `call_expression` | Direct calls |
| calls | `pipe_expression` | `x->f(y)` pipe chains |
| variable | `let_declaration` (when body is not `function`) | Value bindings |

Key fields: `module_binding` has `name` field; `type_binding` has `name` and `body` fields; `let_binding` has `pattern` (name) and `body` fields.

### Tasks

- [x] 3.1 — Fork/clone `@colbymchenry/codegraph` and study the `LanguageExtractor` architecture
- [x] 3.2 — Study existing extractors (TypeScript, Rust, Pascal) to understand the pattern
- [x] 3.3 — Build `tree-sitter-rescript.wasm` via Docker + emscripten (908KB)
- [x] 3.4 — Add `'rescript'` to `Language` type in `src/types.ts`
- [x] 3.5 — Register `.res`/`.resi` extensions and WASM in `src/extraction/grammars.ts`
- [x] 3.6 — Ship `tree-sitter-rescript.wasm` in `src/extraction/wasm/`
- [x] 3.7 — Write ReScript `LanguageExtractor` in `src/extraction/tree-sitter.ts`
- [x] 3.8 — Add ReScript-specific `visitReScriptNode()` for ERROR node recovery, pipe expressions, module nesting
- [x] 3.9 — Add `**/*.res`, `**/*.resi` to default include; `**/lib/bs/**`, `**/lib/ocaml/**`, `**/.rescript/**` to exclude
- [x] 3.10 — Write 12 extraction tests in `__tests__/extraction.test.ts` (all pass, 197 total pass, 0 regressions)
- [x] 3.11 — Tested against reventless-core: 75 nodes, 71 edges, 28 call refs from 4 core files
- [x] 3.12 — Open upstream PR to `@colbymchenry/codegraph` (branch: `feat/rescript-support` at `/tmp/codegraph`)

### Known Challenges

- Modules are the primary organizational unit (no classes) — map to `namespace` NodeKind
- Functors (`Module.Make(Config)`) → map to `calls` edges (instantiation)
- Pipe expressions (`x->f(y)`) need special handling to extract the function being called
- PPX decorators (`@schema`, `@s.matches`) are compile-time only — extract as `decorators` metadata
- `let_declaration` is overloaded — need to distinguish function bindings from value bindings by checking if body is a `function` node

### Acceptance Criteria

- `codegraph_search` finds ReScript symbols (functions, modules, types)
- `codegraph_callers` / `codegraph_callees` traces call relationships through pipe chains
- `codegraph_impact` correctly identifies blast radius for ReScript changes
- All packages in reventless-core are indexed
