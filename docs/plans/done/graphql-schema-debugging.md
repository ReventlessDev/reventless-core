# Plan: GraphQL Schema Debugging & Introspection

## Status: Complete

All steps implemented and tested. 82 test suites (670 tests) pass, zero warnings.

| Step | Status | Notes |
|------|--------|-------|
| 1 | **done** | `GraphQL_SchemaInspector.res` — granular introspection |
| 2 | **done** | Fragment + plugin entry inspectors in same file |
| 3 | **done** | `GraphQL_Server.res` — SDL refs, diagnostics, mismatch detection |
| 4 | **done** | `printSchema` binding + `getLiveSdl`/`printLiveSdl`/`getSchema` |
| 5 | **done** | `DebugSchema.res` — DCB example debug script |
| 6 | **done** | 17 tests in `GraphQL_SchemaInspectorTest.res` |
| Bonus | **done** | Replaced 4x `Obj.magic` with `S.castToUnknown`/`DcbTag.toUnknownSchema` in `Plugin_Builder.res` |

## Problem

There was no way to inspect what GraphQL schemas are generated at any level of the pipeline. When the DCB example produces incorrect or unexpected schemas, debugging required reading through multiple abstraction layers with no visibility into intermediate results.

## Type Erasure Approach

Sury's `S.t<'a>` uses GADT-like private variants — pattern matching only unifies when the type parameter is `unknown`. However, the **public API** of inspector functions accepts polymorphic `S.t<'a>` and casts internally via `S.castToUnknown`. Callers pass typed schemas directly, no `Obj.magic` needed.

`Plugin_Builder.res` now uses `S.castToUnknown` and `DcbTag.toUnknownSchema` (the latter where the module variable `S` shadows sury's `S` module) instead of `Obj.magic` for all schema entry construction.

## Files Changed

| Action | File | Package |
|--------|------|---------|
| **Created** | `src/components/Api/GraphQL_SchemaInspector.res` | reventless-core |
| **Modified** | `src/components/Plugin/Plugin_Builder.res` | reventless-core |
| **Modified** | `src/adapter/GraphQL_Server.res` | reventless-in-memory |
| **Modified** | `src/GraphqlYoga.res` | rescript-graphql-yoga |
| **Created** | `src/DebugSchema.res` | example-dcb |
| **Created** | `tests/adapter/GraphQL_SchemaInspectorTest.res` | reventless-in-memory |

## Guide

See `docs/guides/graphql-schema-debugging.md` for usage instructions.
