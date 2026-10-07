# Plan: the source reader outlines a projection's cases and a spec's transition arms

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/source-reader-with-spans.md](../done/source-reader-with-spans.md) (the rest of its S2) when it closed. Waits for its consumer: the forms-as-views work in reventless-tools (its L7, "the `commandTransition` table and projection outlines", not started). Build it when that starts, not before.<br/>
**Relates to:** [../done/model-sidecar-annotation-arguments.md](../done/model-sidecar-annotation-arguments.md), [../done/gwt-sidecar-refs-and-examples.md](../done/gwt-sidecar-refs-and-examples.md)

---

## In plain words

`reventless-ppx-read` (the source reader, shipped with the PPX) prints a ReScript
file's declarations as JSON, each with its **span** — the byte range it occupies —
so a tool can replace one declaration and leave the rest of the file as written.
It already covers types, cases, fields, attributes, top-level `let`s with value
outlines, and GWT test chains. Two shapes the parent planned are not covered: a
top-level `let` whose body is a `switch` is reported only as an opaque value, so
a tool cannot address one arm of it.

## What is left

1. **Projection cases.** In a `*_Projection.res` file (for example
   `examples/online-shop-hybrid/catalog/src/Product/StateViewStream/Products_Projection.res`),
   each arm of `project`'s `switch`: the event constructor it matches, the effect
   it returns (`Set`, `Update`, `UpdateWithDefault`, `Delete`), its key
   expression, and the arm's span.
2. **Transition arms.** In a spec that declares `let commandTransition` (for
   example `examples/online-shop-hybrid/catalog/src/Category/StateChange/ArchiveCategory.res`),
   each arm: the command, its from-states, its target state, and the arm's span.

Both are pure walks in `packages/reventless-ppx/src/ppx/SourceReader.ml`, beside
the existing outlines, followed by a PPX release (the usual procedure: rebuilt
binary, `test/run.sh`, one commit, CI publishes).

## How to check it

Extend `packages/reventless-ppx/test/reader-spans.mjs` the way the spec and GWT
sections work: over every projection and every spec with a `commandTransition`
in the hybrid example, each reported arm's span cuts exactly that arm's source,
and the named constructor and effect match the source text. Include a file with a
non-ASCII string before an arm (spans are bytes, see the parent's 2026-09-22
fixes).

## Ask the consumer first

The consumer's shape requirements decide details the parent left open — for
example whether an arm with a guard (`| X if …`) or an or-pattern
(`| A | B =>`) is one entry or several. Settle that with the reventless-tools
plan before writing the walk.
