# Docusaurus Documentation Audit

**Date:** 2026-04-04
**Scope:** `packages/doc/` — all four doc plugin instances

---

## Current Structure

Four top-level sections, each an independent Docusaurus plugin instance:

| Section | Route | Source folder | Files |
|---|---|---|---|
| App Guide | `/app` | `docs-app/` | 48 |
| Framework | `/framework` | `docs-framework/` | 17 |
| Providers | `/providers` | `docs-providers/` | 39 |
| Example | `/online-shop` | `docs-online-shop/` | 5 |

---

## Target Audiences

Three real audiences exist. Only two are well-served.

**1. App developer** — "I want to build something with Reventless."
The App Guide covers this well: component reference, both architectural patterns (Aggregate, DCB), testing, concepts.

**2. Framework contributor** — "I want to contribute to the framework."
The Framework Guide covers this adequately: development process, inner workings, component structure patterns.

**3. Evaluator / newcomer** — "What is Reventless? Should I use it?"
This person has no good landing point. There is no home page, no "What is Reventless?", no "Why this framework?" orientation. They land directly in a component reference, which is disorienting. The Online Shop example is actually the best onboarding material on the site — but it sits at the end of the nav.

A fourth implicit audience (infrastructure/ops engineers deploying to AWS) is addressed by the Infrastructure section but could be signalled more clearly from the nav.

---

## Top-Level Menus — Problems

### "Framework" — Wrong Name for Its Content

An app developer sees "Framework" in the nav and naturally clicks it, expecting documentation about the framework from a user perspective. What they find is contributor-internal documentation: message serialization formats, branching strategy, release process, Pulumi internals. This section should be renamed **"Contributing"** or **"Framework Internals"** to signal clearly it is not for users.

### "Example" — Undersells Its Content, Wrong Position

The Example section contains three full architectural pattern walkthroughs (Aggregate-based, DCB-based, Hybrid) plus an AI-generated code review. "Example" (singular) undersells this. More importantly, the walkthroughs are the best onboarding material on the entire site and should be surfaced early — not at the end of the nav. Consider renaming to **"Tutorials"** or **"Walkthroughs"** and moving it to second position in the nav (after App Guide).

### "Providers" → rename to "Infrastructure" ✓ decided

"Providers" is not defined until you're already inside the section. Rename consistently throughout:
- Navbar label: `"Providers"` → `"Infrastructure"`
- Source folder: `docs-providers/` → `docs-infrastructure/`
- Sidebar file: `sidebars-providers.js` → `sidebars-infrastructure.js`
- Sidebar id: `providersSidebar` → `infrastructureSidebar`
- Plugin id: `providers` → `infrastructure`
- Route base path: `/providers` → `/infrastructure`
- Search config `docsRouteBasePath`: update `/providers` → `/infrastructure`
- Footer label: `"Providers"` → `"Infrastructure"`

### Missing: A Home / Introduction Page

There is no top-level landing page visible in the nav that explains:
- What Reventless is
- What problem it solves
- Which section to read first

The site drops you directly into component reference documentation. A proper home page (or a visible "Introduction" nav item) is the highest-priority structural gap.

### Missing: Releases link in Nav

The `packages/doc/CHANGELOG.md` is the *doc site's own* auto-generated changelog (mostly version bumps — not useful to app developers). Per-package changelogs in `reventless/*/CHANGELOG.md` are raw commit messages, too granular and too numerous to surface directly.

The right approach: add a **GitHub Releases** external link to the navbar (semantic-release already populates these automatically). No maintenance burden, canonical source of truth.

Separately, a curated **Migration Guide** page would be high-value — a human-written list of breaking changes per major/minor version with before/after code examples. Cannot be auto-generated; only needs updating on breaking releases.

---

## Section-by-Section Content Assessment

### App Guide (`docs-app/`, 48 files)

**Strengths:**
- Every component has a dedicated doc (24 component files, all detailed, 670–1900 words each)
- Both Aggregate-based and DCB-based plugin guides are thorough
- Testing section is excellent: covers the BehaviorTest, ProjectionTest, and EventMappingTest DSLs with real examples
- Concepts section explains cross-component relationships clearly

**Problems:**

`rescript-syntax.md` (1876 words) — Keep in the App Guide as a standalone reference page. It's the right place for app developers learning to write Reventless code, and the functor section in particular contains valuable Reventless-specific framing that doesn't exist in the official docs. However the content has several issues that need fixing: outdated `option(string)` syntax (should be `option<string>`), `Belt.Int.toString` (superseded by RescriptCore), a stale "future simplification" note about DCB tags that is now wrong (PPX handles auto-injection), a missing pipe operator (`->`) section, a missing `Result` type section (central to how commands work), missing `@@reventless.spec`/`@@reventless.behavior`/`@reventless.projections` PPX annotations, missing `open` statement explanation, and a slightly incorrect first-class modules function example. See `rescript-syntax-content-audit` section below for the full list.

`troubleshooting/common-issues.md` — **33 words, essentially empty.** Just a title with no content. Either fill it with real troubleshooting entries or remove the section until it has content.

`common-modules/Id.md` — **47 words, a near-empty stub.** The ID module is used everywhere in Reventless code. This page should explain `Id.String`, `Id.StringPure`, `Id.T`, and when to use each.

`common-modules/config.md` — 321 words, minimally useful. Could use concrete examples.

`architecture/` (2 files) — Rename the subfolder from `architecture/` to `concepts/` and update the sidebar label from "Architecture" to "Concepts". The files belong in the App Guide — no justification for a new top-level section for just 2 files.

**`ai-assisted/` section (6 files, 300–430 words each) — Audit for business content (see below).**

### Framework Guide (`docs-framework/`, 17 files)

**Strengths:**
- Development process doc (1725 words) clearly explains branching, commits, and release workflow
- Inner workings docs are thorough: messages.md (2499 words), runtime.md (2019 words), resources.md (1588 words)
- Component structure pattern doc (1696 words) is a strong contribution guide

**Problems:**

`architecture/aggregate-extension-connection.md` — 303 words. This is the framework-contributor version of the same file that exists in the App Guide at 1359 words. The sizes are inverted: the contributor version is far thinner than the user-facing version. If the framework version is intentionally a quick reference, that's fine, but 303 words of architectural explanation seems insufficient for a contributor.

`architecture/extension-point-protocol-versioning.md` — 850 words. Solid content, but "protocol versioning" is not mentioned anywhere in the App Guide. If extension point versioning matters to app developers (it probably does when plugins evolve), this should be linked or summarized in the App Guide.

**`ai-skills/` section (6 files, 179–343 words each) — Audit for business content (see below).**

**`inner-workings/mcp.md` (821 words) — Audit for business content (see below).**

### Infrastructure (`docs-infrastructure/`, 39 files) — currently `docs-providers/`

**Strengths:**
- AWS adapter docs are detailed and thorough (400–2100 words per adapter)
- Architecture diagrams and service mappings are clear
- Both development (InMemory) and production (AWS) adapters documented

**Problems:**

`aws/index.md` — 2651 words for an index page. This is the longest index file in the site. Split into an overview + detail pages, or trim significantly. An index should orient, not explain.

InMemory adapter files (12 files, 130–280 words each) — Most are minimal. This is acceptable for a development adapter, but several are thin enough to be stubs. Given that InMemory is the primary tool for local development and testing, these could be slightly more helpful.

`get-started.md` (290 words) and `adapter-pattern.md` (478 words) — Both are short. The adapter pattern explanation could be longer given that it's the foundation of the entire Infrastructure section.

### Example / Online Shop (`docs-online-shop/`, 5 files)

**Strengths:**
- The three architectural pattern walkthroughs (aggregate, DCB, hybrid) are the best onboarding material in the entire site
- Concrete, real-world domain (online shop) makes patterns tangible
- Word counts are appropriate: 1840–3291 words per walkthrough

**Problems:**

`ai-generated.md` — 389 words, thin. Describes an AI-generated code walkthrough but does not contain enough to be standalone. Either expand it or fold it into the relevant pattern walkthrough.

The section name "Example" undersells the content (three full tutorials). Rename and move earlier in nav.

---

## Duplication Analysis

### Intentional — Keep Distinct

`docs-app/concepts/dcb.md` (796 words, usage-focused) vs `docs-framework/architecture/dcb.md` (2650 words, implementation-focused) — Different audience, different depth. Correct to have both.

### No Problematic Duplication

`docs-app/rescript-syntax.md` overlaps with the official ReScript docs but is kept intentionally — it contains Reventless-specific framing (especially the functor section) that doesn't exist externally. The file needs content fixes, not removal. See the `rescript-syntax.md` Content Audit section.

---

## AI-Related Content — Assessment

All three AI-related sections document open source content. The original concern about commercial contamination was unfounded after reviewing the actual file contents.

### `docs-app/ai-assisted/` (6 files) — Open source ✓

The 7 skills (`reventless-app`, `event-sourcing-cqrs`, `event-modeling`, `rescript`, `reventless-testing`, `reventless-aws`, `reventless-context`), 3 slash commands (`/reventless-new`, `/reventless-add`, `/reventless-validate`), and 2 agents (`architecture-reviewer`, `code-reviewer`) all live in `.claude/` of `reventless-core`. The content — domain description, architecture decisions, code walkthrough, iteration patterns — describes the open source framework correctly.

**Two specific references to fix:**
- `index.md` instructs `/plugin marketplace add ReventlessDev/reventless-core` — the plugin marketplace is a Claude Code commercial platform feature, not a framework feature. Replace with direct installation instructions (copy/symlink the `.claude/` folder).
- The MCP server description in `index.md` is correct but thin — link to the full `mcp.md` in the Framework guide instead of duplicating.

### `docs-framework/ai-skills/` (6 files) — Open source, correct placement ✓

Documents how to write, test, and update skills in `.claude/skills/`. Appropriate for the Contributing (Framework) guide. Content is accurate and contributor-facing.

**One reference to fix:**
- `updating-skills.md` instructs bumping version in `.claude-plugin/marketplace.json` and `.claude-plugin/plugin.json`. If these are Claude Code plugin distribution artifacts rather than open source framework files, this instruction should be clarified or moved to internal contributor notes.

### `docs-framework/inner-workings/mcp.md` — Open source, correct placement ✓

The MCP server is genuinely part of the open source framework: `MCP_SchemaGenerator.res` and `SuryToJsonSchema.res` in `reventless-core`, `MCP_Server.res` in `reventless-local`, and a placeholder `MCP_Lambda.res` in `reventless-aws`. The `rescript-mcp-sdk` package provides open source bindings for the open MCP protocol SDK. Content is accurate and correctly placed in Framework internals.

The AWS adapter note ("not yet available") is honestly flagged in the doc itself.

---

## Files That Are Too Short

| File | Words | Problem |
|---|---|---|
| `troubleshooting/common-issues.md` | 33 | Empty stub — fill or remove |
| `common-modules/Id.md` | 47 | Near-empty — needs full explanation |
| `docs-online-shop/ai-generated.md` | 389 | Expand or fold into pattern walkthrough |
| `docs-infrastructure/get-started.md` | 290 | Thin for an entry point |
| `docs-infrastructure/adapter-pattern.md` | 478 | Foundation page, deserves more depth |

---

## Files That Are Too Long for Their Role

### `docs-infrastructure/aws/index.md` (2651 words) — currently `docs-providers/aws/index.md`

An index page should orient — list what's available and link to it. This file tries to do that but buries the navigation under walls of detailed content.

**What belongs on this index page:**
- Overview paragraph + the D2 architecture diagram ✓
- AWS Service Mappings table (component → service) ✓
- Folder structure ✓
- Links to individual adapter pages ✓

**What should be moved or removed:**

| Section | Words | Action |
|---|---|---|
| "Architecture: Deploy-time vs Runtime" (why it matters, 5 bullet points, code example) | ~400 | Move to a new `aws/architecture.md` page |
| "Adapter Structure" + "Deploy-time to Runtime Flow" + `Pulumi.Output.t` explanation | ~300 | Move to `aws/architecture.md` |
| "How Adapters Work" — the `make` pattern with full EventLog + CommandTopic code examples | ~350 | Move to `aws/architecture.md` |
| "Runtime Functions" section with code examples | ~200 | Move to `aws/architecture.md` |
| "Using Adapters" — 4 detailed code examples (EventLog, CommandTopic, QueryDb, TaskBucket) | ~800 | **Remove** — duplicates individual adapter pages; the brief code snippet at the top of each adapter page is sufficient |
| "Testing AWS Adapters" | ~80 | Keep or move to `get-started.md` |

**Result:** Index becomes ~400 words (diagram + table + folder + links). A new `aws/architecture.md` page (~1200 words) covers the deploy-time/runtime pattern with one clear code example. Individual adapter pages already cover the per-adapter details.

---

### `docs-app/rescript-syntax.md` (1876 words)

See the dedicated content audit section below. Concrete proposal: the file stays roughly the same length after changes — some sections added, one removed, several fixed. No structural split needed.

---

## What Should Move to a Different Section

| Current location | Should go to | Reason |
|---|---|---|
| `docs-app/rescript-syntax.md` | Stay in App Guide, fix content | Keep — has valuable Reventless-specific framing; see content issues above |
| `docs-app/architecture/` (2 files) | Rename to `docs-app/concepts/` ✓ decided | No new top-level section; rename subfolder and sidebar label only |
| `docs-online-shop/` (entire section) | Earlier in nav, rename to "Tutorials" | Best onboarding material, buried at the end |
| `docs-app/event-modeling/` (2 files) | Merge into `docs-app/concepts/` | These are usage pattern docs, not a standalone section |
| `docs-framework/architecture/extension-point-protocol-versioning.md` | Link or summarize in App Guide | Relevant to app developers managing plugin evolution |

---

## Recommended Nav Structure

Current:
```
App Guide | Framework | Providers | Example | GitHub
```

Proposed:
```
Get Started | App Guide | Tutorials | Infrastructure | Contributing | GitHub
```

Where:
- **Get Started** — A new home/intro page: what Reventless is, what problem it solves, which section to read next
- **App Guide** — Unchanged content; ai-assisted section is open source and stays
- **Tutorials** — The current "Example" section, renamed, moved earlier
- **Infrastructure** — The current "Providers" section, renamed ✓ decided (folder, route, plugin id, sidebar file all renamed consistently)
- **Contributing** — The current "Framework" section, renamed to signal it's contributor-facing

---

## Priority List

| Priority | Action |
|---|---|
| High | Add a home/intro page — what Reventless is, why, where to start |
| High | Fix `components/commandgenerator.md` H1 — currently "Create", should be "CommandGenerator" |
| Medium | Fix frontmatter/H1 mismatches: `ai-assisted/describe-your-domain`, `ai-assisted/architecture-decisions`, `ai-assisted/generated-code-walkthrough`, `ai-skills/writing-commands`, `ai-skills/updating-skills`, `inner-workings/mcp`, `inner-workings/framework-inner-workings` |
| Medium | Fix `ai-assisted/index.md` — remove plugin marketplace instruction, link to mcp.md instead of duplicating |
| Low | Resolve `in-memory/` folder vs `"InMemory"` sidebar label — pick one casing style |
| Low | Remove empty "Catalog" and "Ordering" categories from `sidebars-online-shop.js` |
| Low | Clarify `.claude-plugin/` versioning in `ai-skills/updating-skills.md` — confirm if open source or Claude Code-specific |
| High | Rename "Framework" → "Contributing" |
| High | Move "Example" / rename "Tutorials" to earlier nav position |
| Medium | Fill `troubleshooting/common-issues.md` with real content |
| Medium | Expand `common-modules/Id.md` to cover `Id.String`, `Id.StringPure`, `Id.T` |
| Medium | Fix `rescript-syntax.md` content — outdated syntax, missing pipe/Result/PPX sections, stale note |
| Medium | Trim `docs-infrastructure/aws/index.md` — too long for an index; see concrete proposal above |
| Medium | Rename "Providers" → "Infrastructure" consistently (folder, route, plugin id, sidebar file) |
| Medium | Rename `docs-app/architecture/` → `docs-app/concepts/` (subfolder + sidebar label) |
| Low | Add a Glossary page (many domain-specific terms with no single reference) |
| Low | Add GitHub Releases external link to navbar (do not link to CHANGELOG.md files) |
| Low | Add `docs-framework/architecture/extension-point-protocol-versioning.md` link in App Guide |
| Low | Expand `docs-providers/adapter-pattern.md` — foundation page deserves more depth |

---

## Title / Folder / Sidebar Consistency Audit

### How Docusaurus resolves titles

Frontmatter `title` controls the sidebar label and the `<title>` tag. If no H1 is present, Docusaurus also renders the frontmatter title as the first heading on the page — no problem. A mismatch only occurs when **both frontmatter title AND an H1 are present and they differ** — the sidebar shows one label, the page starts with a different heading.

### Bug — `components/commandgenerator.md`

Frontmatter title: `"CommandGenerator"` — H1: `"Create"`

The H1 is clearly a leftover from editing. The page opens with the word "Create" as its heading.

**Fix:** Remove the H1 entirely and let Docusaurus render the frontmatter title as the heading. Or change the H1 to `# CommandGenerator`.

### Frontmatter title ≠ H1 mismatches

The general rule: the frontmatter `title` should be a short label suitable for the sidebar. The H1 can be the same or slightly longer for context on the page. They should never say different things.

| File | Frontmatter title | H1 heading | Fix |
|---|---|---|---|
| `ai-assisted/getting-started.md` | "Getting Started" | "Getting Started with AI-Assisted Development" | Acceptable — H1 adds context. Leave as-is. |
| `ai-assisted/describe-your-domain.md` | "Describing Your Domain" | "How to Describe Your Domain" | Change H1 → `# Describing Your Domain` |
| `ai-assisted/architecture-decisions.md` | "Architecture Decisions" | "How the AI Chooses Architecture" | Change H1 → `# Architecture Decisions` |
| `ai-assisted/generated-code-walkthrough.md` | "Generated Code Walkthrough" | "What Gets Generated" | Change H1 → `# Generated Code Walkthrough` |
| `ai-skills/writing-skills.md` | "Writing Skills" | "Writing Portable Skills" | Change frontmatter → `title: Writing Portable Skills` — "portable" is meaningful, keep it in both |
| `ai-skills/writing-commands.md` | "Writing Commands" | "Writing Slash Commands" | Change frontmatter → `title: Writing Slash Commands` — more specific, use it everywhere |
| `ai-skills/updating-skills.md` | "Updating Skills" | "When to Update Skills" | Change H1 → `# Updating Skills` |
| `inner-workings/mcp.md` | "MCP (Model Context Protocol)" | "MCP — AI-native Access to Reventless" | Change frontmatter → `title: MCP Server`; keep H1 as the tagline — short sidebar label, descriptive page heading |
| `inner-workings/framework-inner-workings.md` | "Understand the Inner Workings of the Reventless Framework" | "Framework Inner Workings" | Change frontmatter → `title: Framework Inner Workings` — the current frontmatter is a sentence, too long for a sidebar label |
| `framework/architecture/aggregate-extension-connection.md` | "Aggregate-Extension Connection (Implementation)" | "Aggregate-Extension Connection — Framework Implementation" | Standardise punctuation: change both to use `—` dash style or both to use parentheses. Recommend `title: Aggregate-Extension Connection` and H1 `# Aggregate-Extension Connection — Framework Implementation` |

### Folder name vs sidebar label consistency

Folder names become URL slugs (lowercase-hyphenated by convention) so minor differences from display labels are expected and acceptable. Two cases worth considering:

| Folder | Sidebar label | Recommendation |
|---|---|---|
| `in-memory/` | `"InMemory"` | Leave as-is — URL slug uses hyphens, display label uses camelCase. Both are correct in their context. |
| `ai-skills/` | `"AI Skills Development"` | Shorten sidebar label to `"AI Skills"` — "Development" is redundant in a contributor guide context |

### Online Shop sidebar — empty categories

`sidebars-online-shop.js` defines `"Catalog"` and `"Ordering"` categories with `items: []`. These render as empty collapsed sections.

**Fix:** Remove both empty category entries from the sidebar config. If content for these categories is planned, add it at that point.

### AWS adapter frontmatter title style

All AWS adapter files use `"ComponentName → AWS Service"` (e.g., `"CommandTopic → SQS FIFO"`). Intentional and useful — immediately shows the mapping. Consistent throughout; no change needed.

---

## `rescript-syntax.md` Content Audit

**Decision:** Keep in App Guide as a standalone reference page. The functor section ("Why Functors are Essential in Reventless") is the most valuable content — Reventless-specific framing that doesn't exist in the official ReScript docs. Keep it.

### What's good — keep as-is
- Inline records section — Reventless-specific, not well-covered externally
- Functor section: four-reason breakdown of why functors matter in Reventless — excellent, keep
- PPX section structure — right idea, needs updating (see below)

### Must fix

| Issue | Location | Fix |
|---|---|---|
| Outdated generic syntax: `option(string)` | Line 109 and elsewhere | Change to `option<string>` throughout |
| `Belt.Int.toString` — Belt superseded by RescriptCore | Lines 204, 208 | Use `Int.toString` |
| Stale `:::note Future simplification` — says DCB tags will become `@s.tag` | Bottom of file | Remove — PPX auto-injects DCB tags now (Phase 8); note is wrong |
| First-class modules function example is invalid syntax | Line 271 | Fix or replace with correct functor pattern |

### Missing sections — add

| Missing | Priority | Why it matters |
|---|---|---|
| Pipe operator `->` | High | Used everywhere in Reventless code; appears in examples without explanation |
| `Result` type (`Ok`/`Error`) | High | Commands return `result<array<event>, error>` — central to the framework |
| `@@reventless.spec`, `@@reventless.behavior`, `@reventless.projections` PPX annotations | High | App developers write these in every file; more important than `@s.matches` |
| `@s.matches` placement warning | High | Must go on the type expression, not the field name — silent failure if wrong |
| Update `@s.matches` section | High | Note that PPX auto-injects for `*Id`/`*Ids` fields in slice folders; manual use is edge-case only |
| `open` statement | Medium | Used everywhere (`open Reventless`, `open Spec`); only mentioned incidentally in record scoping example |
| `include` statement | Medium | Merges a module's contents into the current scope; used in Reventless for composing module types |
| Arrays | Low | `array<event>`, array literals — used constantly for event/command return values |
