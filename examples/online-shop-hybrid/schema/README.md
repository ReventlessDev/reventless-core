# GraphQL contract goldens

Committed SDL snapshots of the two GraphQL APIs the hybrid example's local
platform serves. Regenerated and diffed by `pnpm run check:graphql`, which boots
the platform on isolated ports, introspects both servers, and fails on any
difference. Neither file is read at build or runtime — they exist so that a
change to a wire contract shows up as a reviewable diff.

| File | Server | What a diff means |
|---|---|---|
| `platform-api.graphql` | platform admin API (`Platform_*`, plugin-independent) | A UI shell compiles its Relay queries against its own copy of this schema. A diff here means that copy is now stale and has to be regenerated against this platform. |
| `domain-api.graphql` | per-plugin API generated from the hybrid example's specs | No client compiles against this — a shell builds these queries at runtime from the component-definitions manifest. A diff is a report on GraphQL codegen: a changed queryable field, command mutation, filter input, or connection shape. |

Both are `lexicographicSortSchema`-sorted, so they are a function of the schema
alone and don't diff on type-map iteration order.

## When CI fails on these

Read the diff first — it is the answer to "what did I just change about the API".

- **Intended:** run `pnpm run check:graphql:update` and commit the goldens.
- **Unintended:** the diff is the bug report.

A `platform-api.graphql` diff carries a second obligation beyond this repo: a UI
shell holding the old snapshot keeps compiling against the removed or renamed
shape and fails only against a live backend. Refresh the shell's snapshot in the
same change.
