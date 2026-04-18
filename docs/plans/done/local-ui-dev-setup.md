# Plan: Local UI Dev Setup — In-Memory Platform as Browser-Accessible Backend

## Context and Motivation

The in-memory platform starts a graphql-yoga server (port 4000, domain; port 4001, admin/platform in `splitApi` mode). A browser-based UI dev server needs a live, CORS-enabled GraphQL backend to run against locally.

graphql-yoga v5 handles browser CORS natively — no server changes needed.

---

## Scope

| Concern | Status | Action |
|---------|--------|--------|
| CORS for browser fetch from Vite dev server | ✅ handled by yoga v5 | none |
| Schema fetch port for Relay compilation | handled in UI library | none in this repo |
| GraphQL subscriptions (WebSocket) over local dev | ✅ yoga v5 built-in | none |
| Developer startup entry-point | ✅ documented | `docs/guides/local-dev.md` |

---

## Phase 1 — Schema fetch default port

Handled in the UI library. No changes required in this repo.

---

## Phase 2 — Developer startup entry-point ✅

### Steps

- [x] **2.1** Document `LocalDev.res` template pattern in `docs/guides/local-dev.md`
- [x] **2.2** Document full local dev startup sequence (build → start backend → schema update → UI dev server)
- [x] **2.3** Document `splitApi=true` two-port split vs `splitApi=false` single-server mode; environment variable overrides

---

## Phase 3 — Two-tier `dev:full` in platform-in-memory ✅

`dev:full` calls `dev:ui`, which picks the UI dev server in priority order:
1. `reventless-ui` symlink resolves → `npm --prefix reventless-ui run dev:ui` (source repo, hot reload)
2. Symlink absent → `dev-app` binary from installed `@reventless/dev-app` (published snapshot)

Making `@reventless/dev-app` publishable is tracked in the UI library plan.

### Steps

- [x] **3.1** Add `@reventless/dev-app` as `optionalDependency` to platform-in-memory; add `dev:ui` with two-tier fallback; simplify `dev:full`
- [x] **3.2** Update `docs/guides/local-dev.md` to document both tiers
