# GraphQL contract goldens

Committed SDL snapshots of the GraphQL APIs the hybrid example's local platform
serves. Regenerated and diffed by `pnpm run check:graphql` **from the repo root**
(or `pnpm -w run check:graphql` from anywhere), which boots the platform on
isolated ports, introspects both servers, and fails on any difference.

The two goldens do not live together, because they are owned by different things.

| File | Lives in | What a diff means |
|---|---|---|
| `domain-api.graphql` | here | The per-plugin API generated from this example's specs. No client compiles against it — a shell builds these queries at runtime from the component-definitions manifest — so a diff is a report on GraphQL codegen: a changed queryable field, command mutation, filter input, or connection shape. |
| `platform-api.graphql` | `reventless/spec/schema/` | The platform admin API (`Platform_*`, plugin-independent). Framework-owned, not example-owned: this example is only the cheapest way to get a platform serving. It ships from the spec package, and a shell compiles its Relay queries against that dependency. See the README there. |

Both are `lexicographicSortSchema`-sorted, so they are a function of the schema
alone and don't diff on type-map iteration order.

## When CI fails on these

Read the diff first — it is the answer to "what did I just change about the API".
It reports the fields each side has that the other does not, named by the type
they sit in.

- **Intended:** run `pnpm run check:graphql:update` and commit the goldens
  alongside the change that moved them. The diff is the review artifact.
- **Unintended:** the diff is the bug report.
