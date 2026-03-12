# Code Graph Analysis

## What is Code Graph?

"Code Graph" is not a single tool but a category of tools that build graph-based representations of codebases to provide structured context to AI coding assistants. The most prominent implementation is **@colbymchenry/codegraph** — a third-party community tool (not built by Anthropic) that integrates with Claude Code via MCP.

### @colbymchenry/codegraph

- **Repository**: https://github.com/colbymchenry/codegraph
- **npm**: `npx @colbymchenry/codegraph`
- Uses tree-sitter to build a persistent semantic graph stored in a local SQLite database
- Exposes the graph via MCP (Model Context Protocol) for AI assistant consumption
- Claims ~30% reduction in token consumption and ~25% fewer tool calls vs Claude Code's native grep/glob approach

### Other Notable Implementations

| Project | Approach | Backend |
|---------|----------|---------|
| [CodeGraphContext](https://github.com/CodeGraphContext/CodeGraphContext) | Python MCP server, 14 languages | FalkorDB / Neo4j |
| [KnackLabs CodeGraph](https://www.knacklabs.ai/solutions/codegraph) | Commercial enterprise product | Proprietary |
| [codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp) | Go binary, 64 languages | SQLite |
| [code-graph-rag](https://github.com/vitali87/code-graph-rag) | RAG for monorepos, MCP server | Knowledge graph + UniXcoder |

## How @colbymchenry/codegraph Works

### Architecture

```
Source Files → tree-sitter Parser → AST → .scm Queries → Nodes & Edges → SQLite Graph DB → MCP Server → AI Assistant
```

### Indexing Pipeline

1. **Parsing**: tree-sitter parses source files into ASTs
2. **Extraction**: Language-specific `.scm` query files extract semantic nodes (functions, classes, types, variables) and edges (calls, imports, extends, implements, type references)
3. **Storage**: SQLite with FTS5 full-text search + vector embeddings via transformers.js for semantic search
4. **Sync**: Claude Code hooks keep the index updated as files change

### MCP Tools Exposed

| Tool | Purpose |
|------|---------|
| `codegraph_context` | Build comprehensive context for a task (entry points, related symbols, code snippets) |
| `codegraph_search` | Symbol search by name, returns locations |
| `codegraph_callers` | Trace what calls a given function |
| `codegraph_callees` | Trace what a function calls |
| `codegraph_impact` | Calculate change blast radius |

### Language Support (17+ languages)

TypeScript, JavaScript, Python, Go, Rust, Java, C#, PHP, Ruby, C, C++, Swift, Kotlin, Dart, Svelte, Liquid, Pascal/Delphi.

**ReScript is NOT supported.**

### Adding a New Language

Requires two components:

1. **tree-sitter grammar** — npm package for the language's parser
2. **`.scm` query files** — S-expression queries defining how to extract definitions, references, calls, imports from the AST

## Context: Claude Code's Native Approach

Claude Code deliberately uses **on-demand agentic search** (grep, glob, file reads) rather than pre-built indexes. Anthropic experimented with RAG and local vector databases early on but found agentic search outperformed them in precision, simplicity, freshness, and privacy. There is an open feature request for built-in indexing at [github.com/anthropics/claude-code/issues/4556](https://github.com/anthropics/claude-code/issues/4556).

Claude Code also has native LSP support (since v2.0.74) for 11 languages — ReScript is not among them.

## Comparison with Similar Tools

### Tree-sitter Based

| Tool | What it Does | ReScript? | Effort to Add |
|------|-------------|-----------|---------------|
| **@colbymchenry/codegraph** | Semantic code graph via MCP | No | Medium — write `.scm` queries |
| **Aider repo-map** | PageRank-based context selection | No | Medium — add to language pack + write `tags.scm` |
| **ast-grep** | Structural search/lint/rewrite | No (custom possible) | Low — compile grammar + config |
| **Stack Graphs** (GitHub) | Precise name resolution via graph path-finding | No | High — write TSG scoping rules |

### Compiler/Type-Aware

| Tool | What it Does | ReScript? | Effort to Add |
|------|-------------|-----------|---------------|
| **SCIP/LSIF** (Sourcegraph) | Compiler-grade code intelligence | No | Very High — compiler integration |
| **Claude Code LSP** | Native LSP plugin for 11 languages | No | Medium — configure `@rescript/language-server` |

### Embedding/RAG Based

| Tool | What it Does | ReScript? | Notes |
|------|-------------|-----------|-------|
| **Cursor** | Vector-embedding codebase indexing | Yes | Language-agnostic (text-based) |
| **Augment Code** | Cross-repo semantic indexing (MCP) | Likely yes | Language-agnostic |
| **Windsurf Codemaps** | AI-annotated structured code maps | Unknown | Uses SWE-1.5 + Claude Sonnet |

### Academic

| Tool | What it Does | ReScript? |
|------|-------------|-----------|
| **RepoGraph** (ICLR 2025) | Line-level code graph for SWE-bench | No — uses tree-sitter |

### Key Differentiators

- **Syntax-level tools** (tree-sitter based): Fast, incremental, wide language coverage, but no type information or cross-file resolution
- **Compiler-level tools** (SCIP, LSP): Precise type-aware intelligence, but high effort per language and requires build step
- **Embedding-based tools** (Cursor, Augment): Language-agnostic, good for semantic similarity, but no structural understanding

## ReScript Support Analysis

### Existing Foundation

ReScript has two key building blocks already in place:

1. **tree-sitter-rescript** — Official grammar maintained by the ReScript team ([github.com/rescript-lang/tree-sitter-rescript](https://github.com/rescript-lang/tree-sitter-rescript), 594 commits). Used by nvim-treesitter-rescript for syntax highlighting.

2. **@rescript/language-server** — LSP implementation providing go-to-definition, find-references, hover, completions. Used by VS Code extension and Neovim.

### What's Missing

No AI coding tool has first-class ReScript support for structural/semantic code intelligence.

### Option 1: Add ReScript to @colbymchenry/codegraph

**Effort: Medium (1–2 weeks)**

Required work:

1. **Register tree-sitter-rescript** as a parser dependency
2. **Write `.scm` query files** defining extraction patterns for:
   - `let` bindings (function definitions, value bindings)
   - `module` definitions and `module type` declarations
   - Type declarations (records, variants, abstract types, polymorphic variants)
   - `open` statements and module aliases
   - Function application and pipe operators (`->`)
   - Functor applications (`Module.Make(Args)`)
   - External declarations (`@module` bindings)
   - Decorator/PPX attributes (`@schema`, `@s.matches`)
3. **Map ReScript concepts to the graph model** — this is the main challenge:
   - CodeGraph assumes a class/function/method model
   - ReScript is module-centric: modules contain types, values, and sub-modules
   - Functors act as "module factories" — no direct analogue in the graph model
   - Pipe-first (`->`) is syntactic sugar for function application — should edges follow the pipe chain?
4. **Register file extensions** (`.res`, `.resi`)
5. **Test** against a real ReScript codebase (this repo)

**Challenges specific to ReScript:**

- **Module system**: Modules are the primary organizational unit, not classes. The graph would need "module" as a first-class node type.
- **Functors**: `Module.Make(Config)` creates a new module — hard to represent as a simple call edge.
- **PPX decorators**: `@schema`, `@s.matches`, `@module` etc. are compile-time transformations that affect semantics but may not be captured by tree-sitter queries.
- **Pipe operator**: `value->fn1->fn2` — should this create edges `value→fn1` and `fn1→fn2`, or `value→fn1` and `value→fn2`?
- **First-class modules**: `module type T = { ... }` + `let f = (module(M): T) => ...` — dynamic module passing has no equivalent in most graph models.

### Option 2: Claude Code LSP Plugin for ReScript

**Effort: Medium (days)**

Configure `@rescript/language-server` as a Claude Code LSP plugin. This would give Claude Code:
- Go-to-definition
- Find-references
- Hover type information
- Document symbols
- Diagnostics

This is arguably **higher immediate value** than a code graph because it provides type-aware intelligence rather than syntax-level extraction.

**Note**: The workshop:typescript-lsp skill already exists for TypeScript in this project — a similar approach could be taken for ReScript.

### Option 3: ast-grep Custom Language

**Effort: Low (hours)**

1. Compile tree-sitter-rescript as a dynamic library: `tree-sitter build -w tree-sitter-rescript`
2. Register in `sgconfig.yml`:
   ```yaml
   customLanguages:
     rescript:
       libraryPath: tree-sitter-rescript.so
       extensions: [res, resi]
       expandoChar: _
   ```

This enables structural code search/refactoring but does not provide a code graph.

### Option 4: Aider repo-map Support

**Effort: Medium (1 week)**

1. Add tree-sitter-rescript to `tree-sitter-language-pack` (PR to upstream)
2. Write a `tags.scm` query file defining what constitutes definitions and references in ReScript
3. PR to Aider to include ReScript

Only relevant if using Aider as the AI assistant.

## Recommendation

For this project (ReScript monorepo using Claude Code):

| Priority | Action | Effort | Value |
|----------|--------|--------|-------|
| 1 | **Claude Code LSP plugin** using `@rescript/language-server` | Days | Type-aware navigation for Claude Code |
| 2 | **ast-grep custom language** for ReScript | Hours | Structural search/refactoring |
| 3 | **@colbymchenry/codegraph ReScript support** | 1–2 weeks | Reduced token usage, better context |
| 4 | **Aider tags.scm** | 1 week | Only if using Aider |

The LSP plugin provides the highest value-to-effort ratio because it leverages the existing `@rescript/language-server` (already production-quality) and gives Claude Code **type-aware** code intelligence rather than just syntax-level extraction. The code graph approach (option 3) becomes more valuable at scale or if token cost is a primary concern.

## Sources

- [CodeGraph GitHub](https://github.com/colbymchenry/codegraph)
- [CodeGraph npm](https://www.npmjs.com/package/@colbymchenry/codegraph)
- [Claude Code doesn't index your codebase](https://vadim.blog/claude-code-no-indexing)
- [Claude Code indexing feature request #4556](https://github.com/anthropics/claude-code/issues/4556)
- [tree-sitter-rescript](https://github.com/rescript-lang/tree-sitter-rescript)
- [Stack Graphs](https://github.com/github/stack-graphs)
- [SCIP protocol](https://github.com/sourcegraph/scip)
- [ast-grep custom language support](https://ast-grep.github.io/advanced/custom-language.html)
- [Aider repo-map](https://aider.chat/2023/10/22/repomap.html)
- [How Cursor indexes codebases](https://read.engineerscodex.com/p/how-cursor-indexes-codebases-fast)
- [Augment Code Context Engine](https://www.augmentcode.com/context-engine)
- [RepoGraph (ICLR 2025)](https://arxiv.org/abs/2410.14684)
- [Claude Code LSP support](https://www.aifreeapi.com/en/posts/claude-code-lsp)
