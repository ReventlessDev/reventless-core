---
name: rescript
description: >-
  ReScript v12 language patterns for Reventless framework and application code.
  Use when writing, modifying, or reviewing .res/.resi files. Covers syntax,
  module system, sury-ppx serialization, JS interop, and common pitfalls.
---

## Purpose

Provides ReScript v12 coding conventions, pattern templates, and pitfall avoidance for Reventless projects. This skill ensures generated and hand-written ReScript code follows current idioms, compiles without warnings, and works correctly with the sury serialization PPX.

## When to Use

- Writing or modifying `.res` or `.resi` files
- Generating code for Reventless components (aggregates, slices, read models)
- Debugging ReScript compiler warnings or type errors
- Writing JS interop bindings for external libraries
- Working with `@schema` annotations or sury-ppx patterns

## Relationship to ReScript LSP

This skill is complementary to the ReScript Language Server (LSP):
- **LSP** provides runtime code intelligence: hover types, go-to-definition, find-references
- **This skill** provides coding conventions, pattern templates, and known pitfalls
- Both should be active simultaneously: the skill says *how to write* ReScript, the LSP says *what already exists*

## Reference Files

| File | Content |
|------|---------|
| `references/syntax-quick-reference.md` | ReScript v12 syntax essentials |
| `references/module-system.md` | Functors, first-class modules, module types |
| `references/sury-ppx-patterns.md` | `@schema`, DcbTag, serialization patterns |
| `references/interop-bindings.md` | JS interop: `@module`, `@send`, `@val`, `%raw` |
| `references/common-pitfalls.md` | Compiler warnings, type gotchas, known issues |

## Key Rules

1. **Zero warnings policy.** All code must compile without warnings. Check with `npm run build 2>&1 | grep -E "Warning|warning"` after every build.
2. **Use v12 syntax only.** Do not use v11 or older patterns (e.g., `Js.` modules are deprecated; use `RescriptCore` equivalents).
3. **Always add `@schema`** to types that need serialization (commands, events, errors, state in read models/view slices).
4. **Never ignore `Result` or `Option`** — pattern match explicitly.

## Related Skills

- `reventless-app` — generates ReScript code for Reventless components (uses this skill's patterns)
- `reventless-testing` — ReScript testing patterns with Jest in ESM mode
