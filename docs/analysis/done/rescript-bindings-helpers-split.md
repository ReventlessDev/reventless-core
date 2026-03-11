# Analysis: Splitting ReScript Binding Packages into Bindings + Helpers

## Question

Should each `rescript-*` binding package be split into a pure-bindings package and a separate helpers package? How much helper code actually exists, and does this separation make sense?

## Current State

The monorepo contains 13 `rescript-*` packages. An audit of every source file classifies each package as:

| Package | Lines | Classification | Helper Code |
|---------|-------|---------------|-------------|
| rescript-pulumi-aws | ~15,000 | **Pure binding** | None |
| rescript-node-streams | 130 | **Pure binding** | None |
| rescript-node-zlib | 76 | **Pure binding** | None |
| rescript-graphql-yoga | 93 | **Pure binding** | None |
| rescript-hash-object | 14 | **Pure binding** | None |
| rescript-uuid | 21 | **Pure binding** | None |
| rescript-ssh2 | 149 | **Mostly pure** | 2 small helpers (~10 lines) |
| rescript-aws-sdk | 2,719 | **Mixed** | ~80 lines across 4 files |
| rescript-fast-csv | 249 | **Mixed** | ~90 lines of callback adapters |
| rescript-moment | 361 | **Mixed** | ~150 lines of immutable wrappers |
| rescript-pulumi-pulumi | ~2,000 | **Mixed** | ~60 lines in Output.res |
| rescript-effect | 1,860 | **Mixed** | ~200 lines of combinators |
| rescript-mcp-sdk | 279 | **Mixed** | ~50 lines of typed wrappers |

### Summary

- **7 packages are pure bindings** with zero helper code
- **6 packages are mixed**, but the helper code is modest in all of them
- Total helper code across all packages: **~640 lines** out of ~23,000 total lines (~2.8%)

## Nature of the Helpers

The helpers fall into a few categories:

### 1. Immutability Wrappers (rescript-moment)
Moment.js mutates in place. The helpers clone before mutating to provide immutable semantics. These are tightly coupled to the binding types — they only exist because the underlying JS API is mutable.

### 2. Client Singleton Patterns (rescript-aws-sdk: S3, SNS, SQS)
Lazy-initialized `ref(None)` client instances. These are convenience patterns specific to the AWS SDK's client architecture. They'd be awkward in a separate package since they reference the binding types directly.

### 3. Monadic Composition (rescript-pulumi-pulumi, rescript-effect)
`flatMap`, `zip`, `unzip`, `allOpt` on Output.t / Effect.t. These are fundamental combinators that users need immediately when working with the types. Separating them would force every consumer to depend on two packages for basic usage.

### 4. Callback Adapters (rescript-fast-csv, rescript-mcp-sdk)
Convert ReScript idioms (Result types, typed handlers) to the callback/object shapes the JS library expects. These are the most "helper-like" but are still intimately tied to the binding types.

### 5. Utility Functions (rescript-aws-sdk: SQS.arn2Url, DynamoDb_Util)
Small standalone utilities. The only genuinely separable helpers, but at ~20 lines total, not worth a package.

## Assessment: Does the Split Make Sense?

**No.** The split would be counterproductive for several reasons:

### The helper code is too small to justify separate packages
~640 lines across 6 packages. Most packages would get an empty or near-empty helpers package. The overhead of maintaining 6 additional `package.json`, `rescript.json`, npm publishing config, and cross-package dependencies would exceed the code being separated.

### The helpers are tightly coupled to their bindings
Nearly all helpers operate directly on the binding types (Output.t, Moment.t, S3.client, etc.). A `rescript-pulumi-pulumi-helpers` package would need `rescript-pulumi-pulumi` as a dependency and would export functions that only make sense with those types. Consumers would always need both packages together.

### It would hurt developer experience
Users importing `rescript-moment` expect to get `MomentRe.add()` alongside `MomentRe.moment()`. Splitting forces them to know which package has which function and add both dependencies. For the monadic helpers (Output.flatMap, Effect.map), this would be particularly painful — these are not optional conveniences but essential combinators.

### No clear architectural benefit
The typical motivation for a bindings/helpers split is:
- **Multiple helper packages per binding** (different abstraction levels) — not the case here
- **Bindings auto-generated, helpers hand-written** — not the case here (all hand-written)
- **Bindings stable, helpers changing frequently** — not the case (both change together when the upstream JS library changes)

## What Would Make Sense Instead

If the concern is code organization within packages, there are lighter alternatives:

1. **File-level separation within each package**: Already partially done (e.g., `DynamoDb_Util.res` is separate from `DynamoDb_DynamoDb.res`). Could formalize by convention: `*_Helpers.res` suffix for helper files.

2. **Submodule separation**: Group helpers under a `Helpers` submodule within the binding module (e.g., `S3.Helpers.upload()`). Zero package overhead, clear separation.

3. **Do nothing**: The current approach is pragmatic. The helpers are small, well-scoped, and co-located with the types they operate on. This is the standard pattern in the ReScript ecosystem (e.g., rescript-webapi, rescript-promise all mix bindings with helpers).

## Conclusion

The split is **not recommended**. The helper code represents only ~2.8% of total binding code, is tightly coupled to the binding types, and is too small to warrant separate packages. The current co-location is the simplest, most maintainable approach. The overhead of 6+ additional packages (publishing, versioning, dependency management) would significantly outweigh any organizational benefit.
