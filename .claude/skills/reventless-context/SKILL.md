---
name: reventless-context
description: >-
  Pre-implementation discovery for Reventless codebases. Run before writing
  or modifying code to discover existing conventions, find analogous
  components, and prevent pattern drift. Classifies task complexity and
  scales discovery accordingly.
---

## Purpose

Ensures code changes are consistent with the existing codebase by discovering local conventions, finding reusable patterns, and verifying naming/structure before any code is written. Adapted from the context-hunter pattern, tuned specifically for Reventless projects.

## When to Use

Run this skill **before** any implementation task in a Reventless codebase. It should be the first step when:
- Adding a new component (aggregate, slice, read model, extension point)
- Modifying existing components
- Adding a new plugin to a platform
- Refactoring or restructuring code

## Complexity Classification

### L0 — Trivial
Single-line fixes, config tweaks, typo corrections. No context discovery needed — proceed directly.

**Examples:** Fix a typo in a string, update a version number, add a missing comma.

### L1 — Moderate
Bounded changes: new slice, new projection, new extension, adding a field to an existing component.

**Discovery (micro-brief):**
1. Find one analogous component in the same plugin or a sibling plugin
2. Note its naming pattern, file structure, and wiring in the plugin composition root
3. Verify the new name follows conventions
4. Check for potential naming collisions

### L2 — High Risk
Cross-module changes: new plugin, cross-plugin communication, architecture changes, component type changes.

**Discovery (full brief):**
1. Map all existing plugins, their components, and extension points
2. Identify naming patterns across the codebase
3. Check for existing extension point specs that might be affected
4. Verify architecture decisions against `docs/guides/aggregate-vs-dcb-decision-guide.md`
5. Confirm package structure follows monorepo conventions
6. Check for stale build cache from prior reorganization

## Discovery Workflow

1. **Assess completeness:** What information is likely missing from the request?
2. **Find analogous code:** Search for similar components in the same or sibling plugins
3. **Check conventions:** Verify naming, structure, and annotation patterns
4. **Probe for silent knowledge:** Look for implicit patterns (config placement, test organization)
5. **Stop rule:** Continue discovery until you can predict what a reviewer would flag

## Reference Files

| File | Content |
|------|---------|
| `references/discovery-checklist.md` | Reventless-specific discovery checks |

## Key Rules

1. **Never invent names** — derive from at least 2 local analogs when available
2. **Reuse first** — use existing abstractions before creating new ones
3. **Match conventions** — follow established patterns for error handling, testing, module structure
4. **Clarify sparingly** — only ask questions that would change the implementation approach

## Related Skills

- `rescript` — ReScript coding conventions discovered during context analysis
- `reventless-app` — uses discovery results to generate convention-compliant code
- `reventless-testing` — test file organization patterns to match
