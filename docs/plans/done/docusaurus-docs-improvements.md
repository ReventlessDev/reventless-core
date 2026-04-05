# Docusaurus Documentation Improvements

## Status: COMPLETE

**Analysis:** [docs/analysis/docusaurus-docs-audit.md](../analysis/docusaurus-docs-audit.md)

---

## Phase 1: Quick Fixes (no content writing)

### 1.1 — Fix `commandgenerator.md` H1 bug

- [x] `docs-app/components/commandgenerator.md` — no H1 bug found; already correct

### 1.2 — Fix frontmatter/H1 mismatches

Each fix is a one-line change. Rule: frontmatter `title` = short sidebar label; H1 = same or slightly longer on-page heading.

- [x] `docs-app/ai-assisted/describe-your-domain.md` — H1 changed to `# Describing Your Domain`
- [x] `docs-app/ai-assisted/architecture-decisions.md` — H1 changed to `# Architecture Decisions`
- [x] `docs-app/ai-assisted/generated-code-walkthrough.md` — H1 changed to `# Generated Code Walkthrough`
- [x] `docs-framework/ai-skills/writing-skills.md` — already correct
- [x] `docs-framework/ai-skills/writing-commands.md` — already correct
- [x] `docs-framework/ai-skills/updating-skills.md` — H1 changed to `# Updating Skills`
- [x] `docs-framework/inner-workings/mcp.md` — frontmatter changed to `title: MCP Server`
- [x] `docs-framework/inner-workings/framework-inner-workings.md` — frontmatter changed to `title: Framework Inner Workings`
- [x] `docs-framework/architecture/aggregate-extension-connection.md` — frontmatter changed to `title: Aggregate-Extension Connection`; H1 was already correct

### 1.3 — Sidebar housekeeping

- [x] `sidebars-online-shop.js` — removed empty `"Catalog"` and `"Ordering"` category entries
- [x] `sidebars-framework.js` — shortened AI Skills category label to `"AI Skills"`

### 1.4 — Add GitHub Releases link to navbar

- [x] `docusaurus.config.js` — added GitHub Releases link to navbar

---

## Phase 2: Navigation Restructure

### 2.1 — Rename "Framework" → "Contributing"

- [x] `docusaurus.config.js` — updated navbar label: `"Framework"` → `"Contributing"`
- [x] `docusaurus.config.js` — updated footer label: `"Framework"` → `"Contributing"`

### 2.2 — Rename "Example" → "Tutorials", move earlier in nav

- [x] `docusaurus.config.js` — updated navbar label: `"Example"` → `"Tutorials"` and moved to second position (after App Guide)
- [x] `docs-online-shop/get-started.md` — updated title to `Tutorials Overview` and H1 to `Tutorials — Online Shop Example`

### 2.3 — Rename "Providers" → "Infrastructure" (full rename)

Rename consistently throughout — no partial renames.

- [x] `git mv docs-providers/ docs-infrastructure/`
- [x] `git mv sidebars-providers.js sidebars-infrastructure.js`
- [x] `sidebars-infrastructure.js` — renamed sidebar id: `providersSidebar` → `infrastructureSidebar`
- [x] `docusaurus.config.js` — updated plugin config (id, path, routeBasePath, sidebarPath)
- [x] `docusaurus.config.js` — updated search `docsRouteBasePath`
- [x] `docusaurus.config.js` — updated navbar (sidebarId, docsPluginId, label)
- [x] `docusaurus.config.js` — updated footer (label, link)
- [x] Updated all `/providers` links in markdown files to `/infrastructure`

### 2.4 — Rename `docs-app/architecture/` → `docs-app/concepts/`, absorb event-modeling

- [x] `git mv docs-app/architecture/ docs-app/concepts/`
- [x] `sidebars-app.js` — updated paths and label to `"Concepts"`
- [x] Moved event-modeling files into concepts
- [x] `sidebars-app.js` — removed `"Event Modeling"` category; added files to `"Concepts"`
- [x] `rmdir docs-app/event-modeling/`
- [x] Fixed internal links in dcbeventlog.md and aggregate-extension-connection.md
- [x] Grepped and updated remaining `architecture/` links

---

## Phase 3: Content Fixes (existing pages)

### 3.1 — Fix `rescript-syntax.md`

Full details in [analysis/docusaurus-docs-audit.md — rescript-syntax.md Content Audit](../analysis/docusaurus-docs-audit.md).

**Must fix:**
- [x] Replace `option(string)` → `option<string>` throughout
- [x] Replace `Belt.Int.toString` → `Int.toString`
- [x] Removed stale `:::note Future simplification` block
- [x] Fixed first-class modules function example (added parentheses around module params)

**Add sections:**
- [x] Added `->` pipe operator section (after Functions)
- [x] Added `Result` type section (`Ok`/`Error`)
- [x] Added `open` statement section
- [x] Added `include` statement section
- [x] Added Arrays section
- [x] Added Reventless PPX annotations section (`@@reventless.spec`, `@@reventless.behavior`, `@reventless.projections`)
- [x] Updated `@s.matches` section to document PPX auto-injection and placement warning

### 3.2 — Trim `docs-infrastructure/aws/index.md`

Full details in [analysis/docusaurus-docs-audit.md — Files That Are Too Long](../analysis/docusaurus-docs-audit.md).

- [x] Created `docs-infrastructure/aws/architecture.md` with architecture sections
- [x] Added `aws/architecture` to `sidebars-infrastructure.js`
- [x] Removed "Using Adapters" section from index
- [x] Moved "Testing AWS Adapters" blurb to `aws/get-started.md`
- [x] Index is now ~400 words: overview + diagram + service mappings + folder structure + adapter links

### 3.3 — Fix `ai-assisted/index.md`

- [x] Removed `/plugin marketplace add` instruction
- [x] Replaced with copy/symlink instructions for `.claude/` folder
- [x] Replaced inline MCP description with link to MCP Server page

---

## Phase 4: New Content

### 4.1 — Add home/intro page

- [x] Enhanced existing `docs-app/index.md` — added "The Three Sections" table (App Guide, Tutorials, Infrastructure) describing who each is for
- [~] Navbar "Get Started" item not added — index.md already serves as the App Guide landing; a dedicated top-level home page is a bigger change outside scope

### 4.2 — Fill `troubleshooting/common-issues.md`

Currently 33 words (title only). Fill with real content:
- [x] Added: compiler warning 44/32/23 patterns and fixes
- [x] Added: `Component.js` overwrite issue and git restore
- [x] Added: `npm ci` fails / package-lock.json out of sync
- [x] Added: stale ReScript build cache — `npx rescript clean`
- [x] Added: DCB E2E async handler registration fix

### 4.3 — Expand `common-modules/Id.md`

Currently 47 words (near-empty stub):
- [x] Explained `Id.String` (abstract), `Id.StringPure` (transparent), `Id.T` (module type)
- [x] Added usage example with production vs test spec comparison

### 4.4 — Link `extension-point-protocol-versioning.md` from App Guide

- [x] Added "Protocol Versioning" section in `extensionpoint.md` linking to the framework versioning guide

---

## Phase 5: Lower Priority

### 5.1 — Add Glossary page

- [x] Created `docs-app/glossary.md` with all 14 terms defined
- [x] Added to `sidebars-app.js` at the bottom of the App Guide

### 5.2 — Expand `docs-infrastructure/adapter-pattern.md`

Currently 478 words — thin for the foundation page of the entire Infrastructure section:
- [x] Two-level pattern already documented; added InMemory section showing simplified pattern for local dev/testing

### 5.3 — Clarify `.claude-plugin/` versioning in `ai-skills/updating-skills.md`

- [x] Confirmed: Claude Code plugin distribution artifacts (open source / MIT, but Claude Code-specific distribution mechanism)
- [x] Added clarifying note in `updating-skills.md` explaining `.claude-plugin/` purpose and that other assistants don't need it

---

## Summary

| Phase | Scope | Effort |
|---|---|---|
| 1 — Quick fixes | Bug fix, 9 one-line title fixes, 3 sidebar tweaks, releases link | Small |
| 2 — Nav restructure | 4 renames with file moves and config updates | Medium |
| 3 — Content fixes | rescript-syntax rewrite, aws/index split, ai-assisted/index fix | Medium |
| 4 — New content | Home page, troubleshooting fill, Id.md expand, EP link | Medium |
| 5 — Lower priority | Glossary, adapter-pattern expand, .claude-plugin/ clarification | Medium |
