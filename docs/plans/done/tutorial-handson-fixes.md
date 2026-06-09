# Tutorial Hands-On Fixes — Plan

**Source:** [docs/analysis/documentation-journey-review.md](../analysis/documentation-journey-review.md)
§ "Addendum — Hands-on verification (2026-06-09)"
**Created:** 2026-06-09
**Goal:** Make the runnable tutorial steps actually work as written. All findings below were
confirmed by executing the steps / introspecting the live local GraphQL schema. Verified
replacements are given inline.

**Working rule:** update after each step; `git mv` to `docs/plans/done/` as part of the
completion commit.

---

## Phase 1 — User-blocking (copy-paste fails today)

- [x] **H1 — Fix the GraphQL smoke-test snippets** (`docs-tutorials/test-locally.md:51-65`).
  Operations are plugin-prefixed; command mutations return the `CommandResult` **union** (need a
  selection set); read queries return Relay **connections**. Replace with the verified forms:
  - Mutation:
    ```bash
    curl http://localhost:4000/graphql -H 'content-type: application/json' -H 'X-User: admin' \
      -d '{"query":"mutation { Catalog_Category_Add(id: \"books\", name: \"Books\") { __typename } }"}'
    ```
  - Query:
    ```bash
    curl http://localhost:4000/graphql -H 'content-type: application/json' -H 'X-User: admin' \
      -d '{"query":"query { Catalog_Categories { edges { node { id name } } } }"}'
    ```
  - Add a one-line note that field names are `Plugin_…` prefixed and discoverable in GraphiQL
    (the existing pointer at `:67-69` is good — keep it).

- [x] **H2 — Fix the login table** (`docs-tutorials/test-locally.md:18-23`). Replace
  `admin/alice/bob/carol` with the actual seeded users from `users.example.yaml`:

  | Username | Password | Groups |
  |---|---|---|
  | `admin` | `admin` | `Admin`, `User` |
  | `user` | `user` | `User` |

  Update the surrounding prose that says "sign in as `admin`/`admin`" (still correct) and drop the
  `bob`/`carol` group examples.

- [x] **H3 — Fix the backend-default claim (SQLite, not in-memory)** in
  `docs-tutorials/run-locally.md:8-10,74-80` and `docs-tutorials/test-locally.md:71-76`. State that the
  local platform defaults to a **persistent SQLite** store (`.reventless/local.db`), and that the
  ephemeral in-memory backend is the opt-in (`pnpm run serve:memory` / `dev:full:memory`, or
  `REVENTLESS_LOCAL_BACKEND=memory`). Reframe the "Optional: persist" section as "Optional: start
  fresh / use in-memory". Also reconcile `docs-infrastructure/index.md` if it implies in-memory is
  the default.

## Phase 2 — Misleading but not hard-blocking

- [x] **H4 — Fix the link to the gitignored users file** (`docs-tutorials/test-locally.md:16`). Point
  to the committed `platform-local/users.example.yaml` instead of `.reventless/users.yaml` (gitignored
  → 404). Add: "run `node scripts/setup.mjs` (or `cp users.example.yaml .reventless/users.yaml`) to
  seed your local users."

- [x] **H5 — Fix env-var names** (`docs-tutorials/run-locally.md:65-72`). Replace `PORT` / `ADMIN_PORT`
  with the real names (`reventless/reventless-local/src/Platform.res:702-705`):

  | Variable | Effect |
  |---|---|
  | `GRAPHQL_DEBUG=1` | Log every GraphQL request/response |
  | `MCP_DEBUG=1` | Log MCP tool calls |
  | `REVENTLESS_DOMAIN_PORT=NNNN` | Domain API port (default 4000) |
  | `REVENTLESS_PLATFORM_PORT=NNNN` | Platform/admin API port (default 4001) |
  | `REVENTLESS_LOCAL_BACKEND=…` | `memory` or `sqlite:./path.db[?reset]` (default sqlite) |

  (Optionally mention the MCP ports `REVENTLESS_DOMAIN_MCP_PORT` 3001 / `REVENTLESS_PLATFORM_MCP_PORT` 3002.)

- [x] **H6 — Fix "two processes" → three** (`docs-tutorials/run-locally.md:33-34`). `dev:full` runs
  `concurrently --names rs,backend,ui`: a ReScript watcher (`rs`), the backend (`backend`), and the UI
  (`ui`). Reword to "three processes (`[rs]` ReScript watch, `[backend]`, `[ui]`)"; the backend still
  exposes two endpoints (domain 4000, platform 4001).

## Phase 3 — Minor / polish

- [x] **H7 — Terminology** (`docs-tutorials/run-locally.md:39`). 4001 is the **platform** API in code;
  keep "admin" only if clarified as "the platform/admin API (`Admin_*` queries)".
- [x] **H8 — `X-User` is not required for reads** (`docs-tutorials/test-locally.md:48-49`). Note that
  omitting it falls back to `defaultUser`; the header selects a user/groups for authorization, it isn't
  required to get a response.

## Out of scope / no action

- **AWS path** (`deploy-to-aws.md`, `test-on-aws.md`): all referenced dirs/configs/scripts exist; the
  deploy sequence itself was **not executed** (needs an AWS account + Pulumi org). Leave a TODO to do a
  real cloud dry-run when an account is available.
- **"Source B"**: already reworded to "the live-update path" in the prior cleanup; the term is defined
  in `verify-subscriptions.mjs`. No change.
- **app/get-started.md**: recipe is internally consistent and the `generate-plugin` bin exists; a true
  out-of-monorepo fresh-project run was not performed (would need registry install). Optional future check.

## Verification

After edits: rebuild docs (`pnpm --filter ./packages/doc run build`), and re-run the two corrected
curls against a freshly booted backend to confirm they still round-trip.
EOF
echo "plan written: $(wc -l < docs/plans/tutorial-handson-fixes.md) lines"
---

## Completion (2026-06-09)

All eight fixes (H1–H8) applied to `test-locally.md` and `run-locally.md`. Docs build clean
(zero broken links). The two corrected GraphQL curls were re-run verbatim against a live local
backend and execute without validation errors (`Catalog_Category_Add … { __typename }` →
CommandAccepted/Rejected; `Catalog_Categories { edges { node { id name } } }` → data). H7 was
folded into the H6 endpoint-table edit. The infrastructure index already described the two
backends neutrally, so it needed no change. AWS-path and app/get-started items remain out of
scope (not executable here) as noted above.
