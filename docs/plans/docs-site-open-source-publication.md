# Documentation Site — Open-Source Publication Plan

**Scope:** Turn the current four-instance Docusaurus site (`packages/doc/`) plus the
unpublished engineering guides (`docs/guides/`) into the public documentation
experience for `reventless.dev` when this repo goes open source. Adds a
learning-journey information architecture, an end-to-end "online-shop" spine,
a real blog, and an integrated Slidev "Talks" section.

**Status:** In progress. **Phases 0–6 complete** (2026-05-23) — front door,
hybrid spine, all canonical guides, app-dev depth + custom-domain page,
contributor track + "Extending the framework" capstone, and a real blog; docs
build green with **zero broken links**. **Phase 8 domain cutover done (2026-06-25)** —
repo is public, docs live at **https://docs.reventless.dev** (see Phase 8 below
for the actual subdomain decision and the deploy-pipeline fixes it required).
**Phase 7 (Talks) still deferred** (large net-new Slidev subsystem, best done
standalone). **Remaining in Phase 8: 8.3 `onBrokenLinks: throw`** (still `warn` —
there is a known broken anchor on `aws/adapters/dcbeventlog`). The site root
(`/`) is a 0s redirect placeholder to `/alpha/` (the only published version);
visitors land on current alpha docs — no stale content. Optionally publish a
`latest` at root later so the bare URL serves docs without the redirect hop.

**Prior work in this repo:**
- [`docs/analysis/docusaurus-docs-audit.md`](../analysis/docusaurus-docs-audit.md) (2026-04-04) — per-file audit; its structural renames (`providers→infrastructure`, `online-shop→tutorials`, `architecture→concepts`, glossary, Releases link) are already done. This plan supersedes it at the structural level and folds the remaining open items into Phase 0.
- [`docs/analysis/host-ui-custom-domain.md`](../analysis/host-ui-custom-domain.md) — input for the "deploy to your own domain" page (journey E).

**Resolved decisions:**
- **Domain/version layout:** ~~`main` on `reventless.dev` root~~ → **(revised 2026-06-25)**
  docs serve at the **`docs.reventless.dev`** subdomain (`baseUrl: "/"`); the apex
  `reventless.dev` 301-redirects to it via a Cloudflare Redirect Rule (the apex is
  reserved for the `reventless-launch` landing page). Versions live at `/` (main),
  `/alpha/`, `/beta/`. Only `alpha` is published (`main`/`latest` is unpublished),
  so `docs.reventless.dev/` is a 0s redirect placeholder to `/alpha/` — visitors
  get current content; no stale docs are served. Optionally publish a `latest` at
  root later so the bare URL serves docs directly.
- **UI docs scope:** document UI *consumption* (host-shell, Auto UI, custom domain) by package name only — no links to the private UI repo. Package names are fine; repo/internal links are not.

**Open decisions** (each carries a recommended default; resolve before the phase that needs it):
1. **Introduction implementation** — ✅ **RESOLVED (2026-05-23): promoted `docs-app/index.md`** to a "What is Reventless?" page (`sidebar_label: Introduction`) with a navbar "Introduction" entry. Phase 1 done.
2. **Guide migration default** — ✅ **RESOLVED (2026-05-23): `git mv` full**, with a one-line stub left in `docs/guides/` only for the 5 guides referenced by skills/rules/CLAUDE.md (`aggregate-vs-dcb-decision-guide`, `platform-and-plugin-guide`, `querydb-key-design-guide`, `lambda-deployment`, `pnpm-guide`). Phase 3 done.
3. **Blog versioning** — one canonical blog on `main` only **(recommended)** vs. per-version. Affects Phase 6 (not started).
4. **Versions UI** — keep generated `versions.html` selector **(recommended, lowest churn)** vs. in-site `VersionSwitcher`. Affects Phase 8 (not started).
5. **Talk diagram mode** — static-PNG default for published decks **(recommended, ~10× lighter)** vs. runtime-WASM (~2 MB/deck, interactive). Affects Phase 7 (not started).

Also resolved: the Phase 0.3 marketing claim ("production since 2019 / financial industry") — **kept as-is** per the maintainer.

---

## Goal

A reader can walk one continuous, linked path:

**A** understand *what Reventless is* → **B** understand the hybrid online-shop example → **C** run it locally → **D** deploy it to their own AWS and test it → **E** build their own app on their own domain; with a parallel **F** track for contributors (internals → extend the framework).

Three personas, one spine plus two branches:

| Journey | Persona | Section |
|---|---|---|
| A | Evaluator | Introduction (front door) |
| B, C, D | Evaluator → App dev | Tutorial (the spine) |
| E | App dev | App Guide + Infrastructure |
| F | Contributor | Contributing |

**The single biggest content gap:** conceptual pages (Tutorial) and operational pages (guides) never link to each other, and the richest references live unpublished in `docs/guides/`. Every spine page must end with an explicit "next step" link.

---

## Target information architecture

Keep the four plugin instances (they map cleanly to personas); add Introduction, Blog, and Talks.

Target navbar:

```
Introduction | Tutorial | App Guide | Infrastructure | Contributing | Blog | Talks | GitHub ▸ (Releases)
```

| Nav entry | Backed by | Journey | Change vs today |
|---|---|---|---|
| Introduction | promoted `docs-app/index` or new `docs-intro/` + landing page | A | **NEW** nav entry: what / why / who / pick-your-path |
| Tutorial | `docs-tutorials/` | B, C, D | Rename from "Tutorials"; becomes one guided spine |
| App Guide | `docs-app/` | E | Absorbs canonical USER guides |
| Infrastructure | `docs-infrastructure/` | D, E | Absorbs DEPLOY guides; add "deploy your app to your domain" |
| Contributing | `docs-framework/` | F | Absorbs CONTRIBUTOR guides; ordered internals path |
| Blog | new real `blog/` | retention | **NEW** — enable preset blog |
| Talks | `static/talks/*` Slidev SPAs | evangelism | **NEW** — integrate presentations |
| GitHub / Releases | external | — | keep |

Recommended reading paths (place on the landing page and the Introduction page):
- **Evaluator:** Home → Introduction → Tutorial overview → Hybrid walkthrough.
- **App dev:** Tutorial spine (understand → run local → deploy AWS → test) → App Guide → Infrastructure (your own domain).
- **Contributor:** Contributing get-started → Framework internals (ordered) → Component-structure pattern → Extending the framework.

---

## Phase 0 — Pre-public hygiene (High)

Goal: nothing embarrassing ships. Self-contained; do first.

1. **Hero CTA / GitLab link** — `packages/doc/src/pages/index.js`: replace any GitLab reference with the GitHub repo; point the second CTA at "Try the example" → Tutorial.
2. **Site README** — `packages/doc/README.md`: rewrite for a public audience; remove the "WORK IN PROGRESS" banner and `yourorg` placeholders; document UI consumption by package name only, no private-repo links.
3. **Marketing claim** — `packages/doc/src/components/HomepageFeatures/index.js`: confirm "production since 2019 / financial industry" is OK to state publicly, or soften.
4. **Stubs & H1 bugs** (from the 2026-04-04 audit, still open):
   - Fill or remove `docs-app/troubleshooting/common-issues.md` (empty stub).
   - Expand `docs-app/common-modules/Id.md` (`Id.String` / `Id.StringPure` / `Id.T`).
   - Fix `docs-app/rescript-syntax.md`: outdated `option()` syntax, Belt → RescriptCore, stale DCB-tag note; add pipe / `Result` / PPX-annotation sections.
   - Fix the H1 in `docs-app/components/commandgenerator.md` (currently "Create…").
   - Resolve remaining frontmatter/H1 mismatches in `ai-assisted/`, `ai-skills/`, `inner-workings/` (per the audit table).
5. **Over-long index** — split `docs-infrastructure/aws/index.md`; move deploy-time/runtime theory into `aws/architecture.md`.
6. **Delete starter cruft** — `packages/doc/example-docs/` and the four template blog posts under `packages/doc/blog/` (`2019-05-28-first-blog-post.md`, `2019-05-29-long-blog-post.md`, `2021-08-01-mdx-blog-post.mdx`, `2021-08-26-welcome/`).

Acceptance: `grep -ri "gitlab\|yourorg\|work in progress\|reventless-universe"` over `packages/doc/` returns nothing; site builds; no stub pages reachable from a sidebar.

---

## Phase 1 — Front door / Introduction (High) — journey A

1. **Introduction nav entry** (open decision #1). Recommended: promote `docs-app/index.md` into a real "What is Reventless?" page and add a navbar link to it. Content: the problem (event-sourced CQRS on serverless without the boilerplate), the programming model in three sentences, who it's for, and the three doorways below.
2. **Landing page as the front door** — `packages/doc/src/pages/index.js`: hero → one-paragraph "what & why" → three labelled doorways: **"Try the example"** → Tutorial, **"Build an app"** → App Guide, **"Contribute"** → Contributing → feature grid → package map. Rewrite hero/feature copy for a public audience.
3. Add the three reading paths (above) to both the landing page and the Introduction page.

Acceptance: navbar shows an "Introduction" entry that resolves; landing page links resolve to Tutorial / App Guide / Contributing; a newcomer is never dropped straight into reference material.

---

## Phase 2 — The spine: hybrid online-shop, end to end (High) — journeys B, C, D

Built around `examples/online-shop-hybrid/` (real working app: `catalog`/`ordering` plugins + `-spec`/`-aws`, `platform-local/`, `platform-aws/`, `deploy-manifest.yaml`). Target `docs-tutorials/` order:

| # | Page | Status | Source to fold in |
|---|---|---|---|
| 1 | Overview (`get-started.md`) | keep | — |
| 2 | Choosing an approach (Aggregate / DCB / Hybrid) | light edit | `aggregate-vs-dcb-decision-guide.md` (summary + link) |
| 3 | Hybrid walkthrough (`hybrid-based.md`) | **fix drift** | actual `examples/online-shop-hybrid/` source |
| 4 | Run it locally | **NEW** | `local-dev.md` + `local-persistence.md`, reconciled to the package's real scripts |
| 5 | Test it locally | **NEW** | `users.yaml` (admin/admin), ports 4000/4001/5180 |
| 6 | Deploy to your AWS account | **NEW** | `deployment-guide.md`, distilled to "deploy *this* example to *your* account" |
| 7 | Test it on AWS | **NEW** | `platform-aws/verify-subscriptions.mjs` (document it) |
| 8 | `aggregate-based.md`, `dcb-based.md`, `ai-generated.md` | keep as alternates | — |

1. **Rename nav "Tutorials" → "Tutorial"** in `docusaurus.config.js` (it is now one guided track). Keep the three-style comparison as the conceptual core; mark Hybrid as recommended.
2. **Fix tutorial ↔ source drift** in `hybrid-based.md` — reconcile or clearly mark as simplified:
   - It shows hand-written `CatalogPlugin.res` / `*EventLog.res`; reality: `Plugin.res` is **generated** and there is **no `*EventLog.res`** (the DCB log is implied by slices).
   - It uses `StateViewSlice` / `ReadModel`; source uses the live variants `StateViewSliceStream` / `ReadModelStream`.
   - It omits real components: `CatalogActivity` ReadModel, `ImportProducts` Task, `RefundOrder` slice, `EmailService`.
3. **Fix `local-dev.md` before publishing it as page 4:**
   - `dev:ui` fallback is documented as `reventless-playground`; the hybrid package actually falls back to `reventless-host-shell` (optional dep).
   - `dev:full` runs `pnpm run serve` (not `dev:local`).
   - It implies a `reventless-ui` symlink that does **not** exist in a fresh checkout (gitignored); host-shell is the real local-UI path.
4. **Write the deploy/test runbook** (pages 6–7), closing these gaps:
   - "Fork-and-deploy": set your own Pulumi org + `platform:stack` value (configs currently hardcode `reventless/...`); Cognito (auto-provision vs bring-your-own); the **exact** host-shell version pin; the **CloudFront `/*` invalidation** gotcha after host-UI deploys.
   - "Test on AWS": read AppSync/CloudFront URLs from Pulumi outputs, log in against deployed Cognito, run a smoke test (document `platform-aws/verify-subscriptions.mjs`).
5. **Add `examples/online-shop-hybrid/README.md`** — highest-impact single artifact: package map, "build → run local → deploy" commands, and a link back to the Tutorial spine. Anchors readers arriving via GitHub.
6. **Wire "next step" links** end-to-end across pages 1→7, including the cross-link into Infrastructure for the AWS deploy detail.

Acceptance: a reader can follow Tutorial pages 1→7 with no dead ends; every code/script reference matches the actual `examples/online-shop-hybrid/` package; the example README's commands run as written.

---

## Phase 3 — Publish canonical guides (High) — journeys D–F

Decide **one canonical home** per topic. Default (open decision #2): `git mv` the rich guide into the relevant instance; leave a one-line stub + link in `docs/guides/` only if referenced by code/CI. Keep `docs/analysis/` and `docs/plans/` **out** of the published site.

| Guide | Target | Action |
|---|---|---|
| platform-and-plugin-guide.md | App Guide | Migrate as "Build your own app" (canonical) |
| aggregate-vs-dcb-decision-guide.md | Tutorial + App Guide | Summary in Tutorial pg.2, full page in App Guide |
| graphql-api-guide.md | App Guide | Into `components/api.md` area |
| dcb-usage.md | App Guide | Merge into `concepts/dcb.md` |
| given-when-then.md | App Guide | Merge into testing pages |
| reventless-ppx.md | App Guide | Merge into `rescript-syntax.md` / new PPX page |
| local-dev.md | Tutorial pg.4 | Fix (Phase 2), migrate |
| local-persistence.md | Tutorial pg.4 / Infra | Migrate as optional sidebar |
| component-testing-guide.md | App Guide | Merge into testing |
| querydb-key-design-guide.md | App Guide | Migrate |
| ui-fragments-deployment.md | Infrastructure | Migrate (Auto UI + your domain) |
| appsync-events-live-updates.md | Infrastructure | Migrate (live updates) |
| mixed-source-readmodel.md | App Guide | Migrate (advanced pattern) |
| mixed-source-automationslice.md | App Guide | Migrate (advanced pattern) |
| deployment-guide.md | Infrastructure | Migrate (canonical AWS deploy) + Tutorial distill |
| lambda-deployment.md | Infrastructure | Migrate |
| aws-lambda-layer.md | Infrastructure | Migrate |
| application-development-layers.md | Contributing / Infra | Migrate (architecture) |
| api-protocol-integration.md | Contributing | Migrate (extending) |
| transport-adapter-guide.md | Contributing | Migrate (extending) |
| callback-hooks-and-adapter-wrapping.md | Infrastructure | Migrate |
| dual-aws-provider.md | Infrastructure | Migrate |
| contributing.md | Contributing | Merge into get-started |
| component-testing.md | Contributing | Merge (dedupe with USER testing guide) |
| pnpm-guide.md | Contributing | Migrate (dev env) |
| cross-repo-dev-linking.md | Contributing | Migrate (dev env) — scrub UI-repo links |
| registry-and-tokens.md | Contributing | Migrate (dev env) |
| d2-diagrams.md | Contributing | Migrate (docs tooling) |
| rescript-namespaces-and-shadowing.md | Contributing | Migrate (ReScript internals) |
| rescript-monorepo-build-behaviour.md | Contributing | Migrate |
| rescript-option-proxy-pitfall.md | Contributing | Migrate |
| output-types-in-reventless-spec.md | Contributing | Migrate |
| forward-codegen-pipeline.md | — | Moved to the developer-tooling repo |
| graphql-schema-debugging.md | Contributing | Migrate |
| reventless-vscode-testing.md | Contributing | Keep — user docs for the free VS Code extension |
| GITHUB_MIGRATION_GUIDE.md | — | **Deleted** (stale GitLab→GitHub/GH-Packages boilerplate; migration done, npmjs live) |
| GITHUB.IMPLEMENTATION_SUMMARY.md | — | **Deleted** (misdescribed reality: semantic-release/CI-matrix/scope) |
| CICD_SETUP.md | — | **Do not publish** |
| AWS_PACKAGE_SEPARATION.md | — | **Do not publish** |

Per-guide steps: add Docusaurus frontmatter; fix relative links and image/D2 paths; add to the target instance's sidebar in the right position; merge (don't duplicate) where a thin page already overlaps a rich guide — the rich guide wins.

Acceptance: every USER/DEPLOY/CONTRIB guide is reachable from a sidebar exactly once; the four INTERNAL guides remain unpublished; no `docs/guides/` page is published twice; `onBrokenLinks` (still `warn`) emits no new warnings for migrated pages.

---

## Phase 4 — App-dev depth & your own domain (Medium) — journey E

1. **Absorb canonical USER guides** into App Guide (see Phase 3): `platform-and-plugin-guide` → "Build your own app"; `graphql-api-guide` → API; `querydb-key-design-guide` → QueryDb/StateView; `mixed-source-*` → advanced patterns; `given-when-then` → testing.
2. **"Deploy your app to your own domain"** hand-off from App Guide into Infrastructure (host-shell custom domain — input from `docs/analysis/host-ui-custom-domain.md`, plus `ui-fragments-deployment.md`, `appsync-events-live-updates.md`).
3. **Infrastructure:** add the custom-domain page for the deployed host-shell (journey E's "their own domain"); link the thin Local adapter pages from the spine's "run locally" page.

Acceptance: App Guide has a complete "build your own app" path; an Infrastructure page documents pointing the deployed host-shell at a user-owned domain.

---

## Phase 5 — Contributor track (Medium) — journey F

1. **Ordered "Framework internals" reading path** in `docs-framework/inner-workings/`. Files exist (`messages`, `serialization`, `resources`, `runtime`, `pulumi`, `component-structure-pattern`, plus `framework-inner-workings`, `mcp`) but with no prescribed order. Sequence: **messages → serialization → resources → runtime → pulumi → component-structure-pattern → "extending the framework"**. Encode the order in `sidebars-framework.js`.
2. **Absorb CONTRIBUTOR guides** (Phase 3): `contributing` → get-started; `pnpm-guide`/`cross-repo-dev-linking`/`registry-and-tokens` → dev environment; `d2-diagrams` → docs tooling; `rescript-*` → ReScript build internals; `forward-codegen-pipeline`/`graphql-schema-debugging`/`output-types-in-reventless-spec` → internals.
3. **New "Extending the framework" page** (capstone): new component type, new adapter/provider, new API protocol. Reference existing analyses: `gcp-cloud-provider-analysis`, `azure-cloud-provider-analysis`, `supabase-local-platform`, `api-protocol-integration`.
4. Keep `ai-skills/` (open source, contributor-facing).

Acceptance: Contributing sidebar presents internals in the prescribed order ending at "Extending the framework"; CONTRIBUTOR guides are reachable once each.

---

## Phase 6 — Blog (Medium)

Goal: real blog for release notes, design deep-dives, adoption stories — same site, same deploy.

1. **Enable the `blog:` block** (currently commented out, `docusaurus.config.js` ~lines 199–210): `showReadingTime: true`, RSS/Atom feeds, `editUrl` → core repo, `blogTitle`/`blogDescription`, `postsPerPage`.
2. **Real authors/tags** — rewrite `packages/doc/blog/authors.yml` and `tags.yml` (curated tags: `release`, `event-sourcing`, `dcb`, `case-study`, `internals`). (Template posts already deleted in Phase 0.)
3. **Blog navbar entry**.
4. **Seed posts:** (a) "Introducing Reventless"; (b) "Aggregate vs DCB: when to use which" (links the decision guide); (c) "Building the online shop end to end" (links the spine).
5. **Versioning** (open decision #3) — recommended: one canonical blog on `main` only; exclude/empty the blog in beta/alpha builds, or point the navbar Blog link to the root-version blog from all versions. Document this so versioned builds don't fork the blog.
6. **Search** — flip `indexBlog` to `true` (`docusaurus.config.js` line 118) once the blog has real content.

Acceptance: blog renders with real posts, RSS feed, and a navbar entry; versioned builds don't duplicate or fork the blog.

---

## Phase 7 — Talks / presentations (Medium)

Build a Slidev authoring workspace **in this repo** (net-new) and integrate it into the docs site (integration is net-new everywhere — no prior implementation exists).

### 7.1 Author

- Add a `presentations/` workspace (Slidev): `talks/<slug>/slides.md`; a shared `slidev-addon-reventless` workspace package (components / layouts / setup, a `<D2>` wrapper supporting runtime-WASM and static-PNG modes, a ReScript Shiki grammar); a pinned + patched `slidev-addon-d2-diagrams`; and a `scripts/build-diagrams.sh` (`.d2 → .svg → .png`) pipeline.
- Key deps: `@slidev/cli ^52`, `@slidev/theme-default`, `playwright-chromium`, `slidev-addon-d2-diagrams` (git pin + pnpm patch), `vue ^3.5`. External: `d2` CLI (static-PNG/PDF export only).
- First decks: an "Executable Event Model" talk and a new "What is Reventless?" intro deck for journey A.

### 7.2 Integrate into the docs site

- Build each deck for its subpath into the docs static dir:
  `slidev build --base <BASEURL>/talks/<slug>/ --out packages/doc/static/talks/<slug> talks/<slug>/slides.md`
- Docusaurus serves `static/talks/<slug>/index.html` at `<site>/talks/<slug>/`. **Link, don't embed** (no iframes): a "Talks" navbar entry + an index page listing decks (title, abstract, link).
- **Base-path is the #1 failure mode**, doubly so with multi-version: a deck under `/alpha/` needs `--base /reventless-core/alpha/talks/<slug>/` (or `/alpha/talks/...` once on the apex). Tie `--base` to the same version/baseUrl logic the docs build already uses.
- Diagram mode (open decision #5) — recommended static-PNG default (~10× lighter than the ~2 MB WASM runtime). GitHub Pages caps ~1 GB/deploy — fine for a handful of decks.

### 7.3 CI

- Extend `.github/workflows/deploy-docs.yml`: before each branch's `docusaurus build`, build each deck with the correct `--base` into `packages/doc/static/talks/`. Decks ride the existing Pages artifact.

Acceptance: `/talks` lists the decks; each deck loads correctly under root and under `/beta//alpha/` sub-paths with no broken asset paths.

---

## Phase 8 — Domain cutover & link hardening (Medium)

**8.1 Custom domain — ✅ DONE (2026-06-25), on `docs.reventless.dev` (not the apex).**
The repo was made public, GitHub Pages enabled (source = GitHub Actions), and the
docs cut over to the custom domain:
- `docusaurus.config.js`: `url: "https://docs.reventless.dev"`, `baseUrl: "/"`.
- `deploy-docs.yml`: per-version base rewrites now `/` → `/alpha/` & `/beta/`,
  manifest `BASE=""`, wget-mirror URL → the custom domain, and a `CNAME` file
  (`docs.reventless.dev`) written on every deploy so Pages never drops the domain.
- DNS (Cloudflare, grey-cloud `docs` CNAME → `reventlessdev.github.io`); apex
  `reventless.dev` 301→docs via a Cloudflare Redirect Rule. Let's Encrypt cert
  issued, Enforce-HTTPS on. (Details + the grey-cloud/Worker-wildcard caveat live
  in auto-memory `reference_publishing_gate_and_pages`.)

This cutover also required **five pre-existing deploy-pipeline bugs to be fixed**
before the alpha docs would build/deploy at all (cwd-independent
`workspace-setup.mjs`; wipe `node_modules` between branch builds; escape
`${NPM_TOKEN}` in MDX; install the `d2` CLI; convert the lone Mermaid diagram to
D2). Captured in auto-memory `reference_deploy_docs_pipeline`.

Separately, push-triggered npm publishing was gated behind the `PUBLISHING_ENABLED`
repo variable (currently `false`) so docs pushes don't trigger the blocked publish.

**8.2 Org/repo sweep** — `ReventlessDev/reventless-core` already in config; re-verify
no `yourorg`/GitLab/`reventless-universe` references remain.

**8.3 `onBrokenLinks: throw` — ⏳ NOT DONE.** Still `warn`. Blocker: a known broken
anchor `#conditional-append-optimistic-concurrency` on
`infrastructure/aws/adapters/dcbeventlog`. Fix that anchor, then flip to `throw`.

**8.4 Content-at-root — ℹ️ optional polish, not a bug.** `docs.reventless.dev/` is a
0s redirect placeholder to `/alpha/` (verified: `default: alpha`, `latest` unpublished
in `versions.json`); visitors reach current alpha docs immediately. If desired,
publish a `latest` (fast-forward `main`, or change the default version) so the bare
root serves docs without the redirect hop. No stale content is served today.

Acceptance: ~~`reventless.dev` serves `main` at root~~ → `docs.reventless.dev` serves
current docs (✅; `/` → `/alpha/`); D2/search/edit URLs resolve under the new base
(✅); CI build green with `onBrokenLinks: throw` (⏳ 8.3).

---

## Roadmap summary

| Phase | Theme | Priority | Status |
|---|---|---|---|
| 0 | Pre-public hygiene | High | ✅ Done (2026-05-23) |
| 1 | Front door / Introduction | High | ✅ Done (2026-05-23) |
| 2 | The spine (run-local → deploy-AWS → test) + example README | High | ✅ Done (2026-05-23) |
| 3 | Publish canonical guides | High | ✅ Done (2026-05-23) |
| 4 | App-dev depth & your own domain | Medium | ✅ Done (2026-05-23) |
| 5 | Contributor track | Medium | ✅ Done (2026-05-23) |
| 6 | Blog | Medium | ✅ Done (2026-05-23) — one canonical blog on main |
| 7 | Talks | Medium | ⏸️ Deferred (large net-new Slidev workspace) |
| 8 | Domain cutover & link hardening | Medium | 🔶 Mostly done (2026-06-25) — cutover to docs.reventless.dev live (`/`→`/alpha/`); remaining: 8.3 `onBrokenLinks: throw` (8.4 root-redirect is fine; publishing a `latest` is optional) |

Phases 0–3 are the minimum for a credible open-source launch; 4–8 are follow-on polish. Phases 6 and 7 are independent and can run in parallel with 4–5.
