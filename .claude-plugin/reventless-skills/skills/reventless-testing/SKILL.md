---
name: reventless-testing
description: >-
  Testing patterns for Reventless applications. Use when creating tests,
  debugging test failures, or understanding the BehaviorTest DSL,
  E2E test patterns, mock strategies, and Jest ESM mode gotchas.
---

## Purpose

Provides testing patterns, templates, and debugging guidance for Reventless applications. Covers unit tests (BehaviorTest DSL, decision tests), projection tests, E2E integration tests with the local platform, and common Jest/ESM pitfalls.

## When to Use

- Creating new tests for aggregates, slices, read models, or projections
- Debugging test failures (especially async/ESM-related)
- Setting up E2E tests with the local platform
- Writing mock storage or mock services for tests
- When `reventless-app` generates test files

## Reference Files

| File | Content |
|------|---------|
| `references/behavior-test-dsl.md` | givenEvents/whenCmd/thenEvent patterns for aggregates |
| `references/e2e-test-patterns.md` | Local platform wiring, Bus setup, async resolution |
| `references/mock-patterns.md` | Factory functions, counter-based failure injection, reset |
| `references/jest-esm-gotchas.md` | testPromise broken, fake timers, @jest/globals, Array.getUnsafe |

## Key Rules

1. **Use `jestTest` for async tests**, not `testPromise` (it's broken — doesn't await promises)
2. **Import `jest` from `@jest/globals`** in ESM mode (not injected as global)
3. **Use intermediate variables** for `Array.getUnsafe(n).field` access
4. **Call `beforeAllAsync`** in DCB E2E tests to resolve Output chains before testing
5. **Reset mocks in `beforeEach`** — use factory functions returning closures over `ref` values

## Related Skills

- `rescript` — ReScript language patterns used in test code
- `reventless-app` — generates test files using these patterns
