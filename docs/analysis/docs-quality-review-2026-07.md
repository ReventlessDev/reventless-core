# Docs Site Quality Review — July 2026

**Date:** 2026-07-05
**Scope:** All published Docusaurus pages in `packages/doc/` — `docs-app/` (60 files, ~98k words), `docs-framework/` (42 files, ~50k words), `docs-infrastructure/` (44 files, ~41k words), `docs-tutorials/` (10 files, ~13k words), `blog/` (3 drafts), plus sidebars, `docusaurus.config.js`, README, CONTRIBUTING.
**Review axes:** completeness, duplication, consistency, briefness/readability for readers without deep event-sourcing/CQRS/ReScript/AWS background, commercial-content leakage, removal candidates, missing topics.
**Method:** Five parallel deep-read reviews (one per section, one tutorials+blog+navigation, one cross-section duplication/consistency audit with grep/link verification against source code in `reventless/`, `packages/reventless-ppx/`, and `examples/`).
**Prior audits:** [docusaurus-docs-audit.md](docusaurus-docs-audit.md) (2026-04-04, structure-focused) and [documentation-journey-review.md](documentation-journey-review.md) (2026-06-09, journey-focused). This review supersedes neither but is broader: every page read, claims verified against current source.

---

## Executive summary

The site's **structure is healthy**: one clear landing page with persona routing, all 156 pages registered in sidebars (one deliberate draft orphan), zero broken sidebar refs, all 73 cross-section route links resolve, DCB is consistently expanded as "Dynamic Consistency Boundary", no internal plan-number leakage, and code fences are uniformly `rescript`. The newest pages (dcbeventlog adapter, dcb-consistency-checks, plugin-lifecycle, custom-domain, graphql-api-guide, given-when-then, local adapter set) are excellent and should serve as templates.

The problems are **staleness and layering**, not architecture:

1. **A cluster of pages still documents removed APIs** — the pre-generated-API era (`components/api.md`, `common-modules/config.md`, half of `commandgenerator.md`), the pre-Spec/Behavior DCB API (`docs-framework/architecture/dcb.md` documents a `Plugin.DcbSpec` that does not exist in the code), the legacy test helpers (`writing-unit-tests.md`), and the old npm scope `@reventless/*` in both provider get-started pages. A new user's **first install command fails** and an evaluator meets a Plugin API that contradicts what the tutorial just taught.
2. **Copies have diverged.** Tutorials duplicate the platform-and-plugin-guide's walkthroughs with 8 verified drift points; the guide contradicts itself internally (Aggregate vs Delegate, EP filenames); three guides spell the `@index` annotation three incompatible ways.
3. **Framework internals leak into app docs and vice versa** — `dcb-usage.md` carries `Obj.magic` war stories and a reference to the maintainer's private `MEMORY.md`; the app-side `aggregate-extension-connection.md` quotes `Plugin_Helpers.res` line numbers while its framework twin is a stub.
4. **A handful of commercial/internal mentions** must be scrubbed (see §5) — the site is otherwise clean of commercial content.
5. **Two high-value topics have no home**: Authorization and Local development workflow.

---

## 1. What's working well (keep as templates)

- `docs-infrastructure/local/adapters/*` — tight, uniform template (Source / AWS equivalent / How it works / Operations / Key differences). **Best adapter template on the site.**
- `docs-infrastructure/aws/adapters/dcbeventlog.md` — delegates concept to app pages, documents only physical layout. The model for retrofitting the older AWS adapter pages.
- `docs-framework/internals/dcb-consistency-checks.md`, `internals/plugin-lifecycle.md`, `internals/component-structure-pattern.md` (linked 23× from other sections — de-facto hub, keep stable), `rescript-option-proxy-pitfall.md`.
- `docs-app/graphql-api-guide.md`, `given-when-then.md`, `aggregates.md`, `dcb-slices.md`, `concepts/directives.md`, `reventless-ppx.md`.
- `docs-infrastructure/custom-domain.md`, `deployment-guide.md`.
- Tutorials spine ordering (hybrid promoted, alternates demoted) and the landing page's three persona cards.
- Blog hidden-state toggles (draft flags, navbar, search index) are all consistent.

---

## 2. Critical factual errors (fix first — these destroy trust)

| # | Where | Error |
|---|---|---|
| 1 | `docs-infrastructure/aws/get-started.md:22`, `local/get-started.md:18`, `docs-framework/internals/pulumi.md:105-106` | Wrong npm scope: `@reventless/reventless`, `@reventless/aws` etc. Actual: `@reventlessdev/reventless-core`, `@reventlessdev/reventless-aws`, … The first command a new user runs fails. |
| 2 | `docs-infrastructure/aws/get-started.md` | Stale end-to-end: `infra/index.ts` TypeScript layout, `ReventlessAws.Plugin.Make({let name=…})` + `Plugin.make(~aggregates=[…])` — matches no current API (current: `Make(Platform)` functor + `Platform.deployPlugin`); `__tests__` dir doesn't exist; layer YAML block incomplete. |
| 3 | `docs-framework/architecture/dcb.md` | Documents `Plugin.DcbSpec` module type — **does not exist anywhere in `reventless/*/src`**. Also old slice API (`reduce`/`initialDecisionModel`/`decisionModel` instead of `initialState`/`evolve`/`decide`), hand-written `@s.matches` (now PPX-injected), and "one FIFO queue per plugin" contradicting the current sync-default/async-FIFO model. |
| 4 | `docs-tutorials/choosing-an-approach.md:39-40` and `blog/2026-05-23-building-the-online-shop-end-to-end.md` | Both say Category is an **aggregate**; the hybrid example code (`examples/online-shop-hybrid/catalog/src/Category/StateChangeSlice/`) and `hybrid-based.md` model Category as **DCB** — the docs contradict the tutorial's own teaching point. |
| 5 | `hybrid-based.md:21`, `run-locally.md:14`, `test-locally.md:18`, and all four `editUrl`s in `docusaurus.config.js` (lines 218/231/244/257) | `tree/main` GitHub links — `origin/main` has no `examples/` and no `packages/doc/` content → every link 404s today. Derive from `docsVersion` or pin to `alpha`. |
| 6 | `docs-app/components/api.md` | Describes hand-written GraphQL SDL + manual AppSync config — directly contradicts `graphql-api-guide.md`'s fully generated API. |
| 7 | `docs-app/common-modules/config.md` | Legacy Config module type (`api`, `apiRole`, `userPoolId`) + `Plugin.Make(MyPluginSpec, MyConfig)` — contradicts the Platform pattern used everywhere else. |
| 8 | `docs-app/components/commandgenerator.md` | Half stale: old `init/apply/execute` behavior contract, hand-written `mutationsSchema`. |
| 9 | `docs-app/graphql-api-guide.md:219` | Documents `@noApiVariants([…])` — annotation does not exist in the PPX source (variant-level `@noApi` is the real mechanism). |
| 10 | `docs-app/dcb-usage.md:~881` | "See the `MEMORY.md` note on payload-less variants" — references the maintainer's **private assistant memory file**. Remove. Line 32 also carries the stale "one FIFO queue per plugin" intro contradicted by lines 52/445/492 of the same page. |
| 11 | `docs-framework/internals/messages.md` | Self-contradictory: top half documents current `meta` (optional `ip?`/`user?`, `causationId`, `traceparent`); the Examples + Reference sections (~lines 324, 570) show the old non-optional record and a correlation rule that contradicts `deriveMeta` (correlationId is inherited; parent msgId becomes causationId). |
| 12 | `docs-framework/ppx-binary-management.md` | "Binaries are committed to the repository" — they are gitignored now; documented workflow (build → commit binary) is obsolete (distribution via republish). |
| 13 | `docs-framework/transport-adapter-guide.md` | "`QueryDb_Callback` planned but not yet implemented" — it exists (`reventless-core/src/components/QueryDb/QueryDb_Callback.res` with `queryInterceptorHook`). |
| 14 | 5× `docs-infrastructure/aws/adapters/` front-matter titles contradict page bodies | `task.md` (title "Lambda + SQS" / body S3), `queryengine.md` ("API Gateway" / DynamoDB), `commandgenerator.md` ("EventBridge Pipes" / AppSync), `heartbeat.md` + `scheduledpublisher.md` (EventBridge / CloudWatch Events). Looks like a mass retitle that never reached the bodies — the sidebar shows one AWS service, the page another. |
| 15 | `docs-infrastructure/aws/adapters/eventtopic.md` + `eventcollector.md` vs `lambda-deployment.md` §8 | The adapter pages present SNS→SQS-FIFO as *the* event-delivery path; lambda-deployment lists the AWS defaults as `EventTopicPublisher.DynamoDbStream` / `EventCollectorChannel.DynamoDbStream`. The section disagrees with itself about the production event path — reconcile against source. |
| 16 | `docs-tutorials/run-locally.md` | Missing bootstrap prerequisites: no `pnpm install` and no `pnpm run setup` (seeds `users.yaml` — the known fresh-clone blocker). Reader hits the login wall one page later. `test-locally.md`'s `node scripts/setup.mjs` also implies the wrong cwd (script is repo-root). |
| 17 | `docs-tutorials/deploy-to-aws.md` | Hardcoded host-shell pin `3.0.0-alpha.28`; actual is `alpha.33`. Reword to "check the current pin in platform-aws/package.json". |
| 18 | `docs-app/components/readmodel.md:219-226` | Four literal `TODO` markers in the idResolvers reference — shipped placeholders. |
| 19 | `docs-framework/graphql-schema-debugging.md` | `cd examples/dcb/example-dcb` (twice) — path doesn't exist; `DebugSchema.res` exists nowhere, so the whole "DCB Example Debug Script" section dangles. |
| 20 | `docs-infrastructure/local-persistence.md:14` | `InMemory.Platform.MakeWithConfig` — stale module name (current: `ReventlessLocal.Platform.MakeWithConfig`); "five surfaces" heading over a six-row table. `local/index.md` "Persistence: None" also contradicts the SQLite backend; `local/adapters/task.md` "no actual storage" contradicts local-persistence's SQLite TaskBucket. |
| 21 | Stale test tooling refs | `@glennsl/rescript-jest` still prescribed in `platform-and-plugin-guide.md:1491,1498`, `docs-framework/component-testing.md`, `component-testing-guide.md`, `rescript-namespaces-and-shadowing.md` — repo migrated to `@reventlessdev/rescript-jest`. `writing-unit-tests.md:15` references `packages/reventless/test-helper/` (doesn't exist); `component-testing-guide.md:25` references `packages/reventless/tests/` (pre-relayout). |
| 22 | `docs-tutorials/aggregate-based.md` §6, `hybrid-based.md:383`, several component pages | `Plugin.make(~uiBundleUrl=?)` + `CatalogMaker` `Main.res` snippets — shipped examples use `let make = ()` and the simple 11-line `Main.res`. Signature shown inconsistently across ~6 pages. |
| 23 | `docs-tutorials/ai-generated.md` | Internal contradiction (prompt says auto-ship "after 24 hours", generated design ships immediately); phantom "port 4002"; never names or links the actual AI tooling (`/app/ai-assisted/`, MCP). |
| 24 | `docs-framework/forward-codegen-pipeline.md`, `reverse-codegen-pipeline.md`, `reventless-vscode-testing.md` | Document packages that are **not in this repo** (moved to `reventless-tools`); repo-relative commands and GitHub links 404. forward-codegen also links nonexistent `docs/analysis/spec-implementation-split.md`. |

---

## 3. Duplication map (canonical owner → what the others become)

| Topic | Copies today | Canonical owner | Others become |
|---|---|---|---|
| DCB concept & usage | `docs-app/concepts/dcb.md`, `docs-app/dcb-usage.md`, `docs-app/dcb-slices.md`, `docs-framework/architecture/dcb.md`, `concepts/statechangeslice-usage.md` (+identical opening paragraph in three of them; the registerHandler/`Obj.magic` internals block is verbatim in both dcb-usage and framework/dcb) | Tutorial: `dcb-slices.md`. Tags/partitioning/`@crossPartition`: `dcb-usage.md` (front half). Internals (registerHandler, serialization): rewritten `docs-framework/architecture/dcb.md` | `concepts/dcb.md` → genuine beginner "What is a DCB?" explainer (tag/fence/decision-model defined before use) or fold away; delete internals appendix from `dcb-usage.md` |
| Walkthrough code | `platform-and-plugin-guide.md` vs `aggregate-based.md`/`dcb-based.md` — full duplicated walkthroughs with **8 verified drift points** (Behavior state shape, read-model fields, EP/Extension style, `heartbeatInterval` 60 vs 5, three `Main.res` shapes, command names) | The guide (after fixing its own stale aggregate EP/Extension sections: `module Aggregate` → `@@reventless.extension` + `module Delegate`) | Tutorials keep narrative + domain tables + short excerpts, deep-link into guide anchors. Currently **zero links** in either direction. |
| EP/Extension/Main.res tutorial sections | Near-verbatim in `aggregate-based.md` and `dcb-based.md` (both admit "same as the other approach") | One of the two (or a shared section) | Link, as `hybrid-based.md` already does |
| GWT testing | `writing-unit-tests.md` (legacy `BehaviorTest.Make` API) vs `given-when-then.md` (current PPX path) — never mention each other; near-duplicate assertion tables | `given-when-then.md` | `writing-unit-tests.md`: delete, or reduce to a legacy-helpers stub; merge its Best Practices section |
| Running tests | `running-tests.md` (framework-repo instructions) + duplicated inside `writing-unit-tests.md:489-506` with drifted paths | `running-tests.md`, rewritten for app projects (pnpm, `reventless-gwt`) | drop the copy |
| Component vs adapter pages | Older `aws/adapters/*` (querydb worst: re-documents all six operations mirroring `docs-app/components/querydb.md:74-213`; also commandtopic, task, counter, heartbeat, eventcollector "When to Use" sections) | Concept/operations: `docs-app/components/*`. Physical layout/IAM/config: adapter pages | Retrofit to the `dcbeventlog.md` template; add back-links (currently 10+ component→AWS-adapter links, **zero** adapter→component, **zero** anything↔local-adapter) |
| Sync/async (`@@reventless.async`) | Explained in full in ~6 places (aggregates, dcb-slices, dcb-usage, guide, aggregate.md, commandtopic.md, concepts/dcb) | `components/commandtopic.md#sync-vs-async` | One sentence + link |
| PPX annotations | `reventless-ppx.md` (canonical, matches PPX source), `querydb-key-design-guide.md` (own annotation reference, wrong syntax), `graphql-api-guide.md` §6.4 (third syntax), component pages | `reventless-ppx.md` | Key-design guide keeps patterns/queries, links for syntax |
| Mixed-source ReadModel | `mixed-source-readmodel.md`, `platform-and-plugin-guide.md` (same Customers example near-verbatim), `readmodel.md#multiple-sources` | `mixed-source-readmodel.md` | Summaries + links |
| Lambda layer | `aws/get-started.md`, `lambda-deployment.md` §4, `aws-lambda-layer.md` | `aws-lambda-layer.md` | 2 sentences + `REVENTLESS_LAYER_ARN` + link |
| Custom domain | `custom-domain.md`, `ui-fragments-deployment.md` §4 (full resource list again), `deployment-guide.md` §4f | `custom-domain.md` | One line + link |
| Adapter pattern / two-layer model | `adapter-pattern.md`, `aws/architecture.md` (near-verbatim EventLog example), `index.md` | `adapter-pattern.md` (concept); `aws/architecture.md` (AWS file conventions only) | Also delete adapter-pattern's stale "InMemory Adapters" section (contradicts current `_InMemory`/`_Sqlite` + `Local*` naming) → link `local/index.md` |
| Workspace-link mechanics | `contributing.md`, `pnpm-guide.md`, `cross-repo-dev-linking.md` (3×) | `cross-repo-dev-linking.md` | 2-line pointers |
| Mock/testing conventions | `docs-framework/component-testing.md:50-81` copies `docs-app/component-testing-guide.md` snippets verbatim | App-side pattern guide | Framework page keeps two-layer architecture only; drop the hand-maintained per-file test index (constant drift) |
| Aggregate-extension connection | Split direction **inverted**: app page (`docs-app/concepts/…`, 377 ln) contains the `Plugin_Helpers.res:82-102` internals; framework page (69 ln) is the stub | Framework page gets the implementation walkthrough | App page shrinks to usage-level mental model + diagram + link |
| Domain tables | `docs-tutorials/get-started.md` tables repeated in all three implementation pages (4×) | `get-started.md` | Link |

---

## 4. Consistency issues

**API/convention contradictions (reader-facing):**
- **`@index` syntax — three incompatible spellings**: `reventless-ppx.md` `@index({projection: "KEYS_ONLY"})` (correct, matches PPX source) vs `querydb-key-design-guide.md` `@index(~projection=KEYS_ONLY)`, `@index(~include=[…])` (`include` is a reserved word — cannot be right) vs `graphql-api-guide.md` `@index(~name="byOwner")`. This is the most-used read-model feature.
- **Behavior contract naming**: `glossary.md` says `handle`/`apply` (pre-decide/evolve API); `commandgenerator.md` says `init/apply/execute`; everything else `initialState`/`evolve`/`decide`.
- **Extension delegate module**: `module Aggregate` (guide line 575, `extension.md` module type) vs `module Delegate` (guide lines 666/1078, all DCB examples, current convention).
- **EP spec filename**: `Products_ExtensionPoint.res` (plugin-system.md, matches `.claude` rules) vs `ProductsExtensionPoint.res` (guide, reventless-ppx.md).
- **`Plugin.make` signature**: `make = ()` vs `make = (~uiBundleUrl=?)` — inconsistent across ~8 pages; shipped generator emits `make = ()`.
- **"exactly-once" claims** in `aws/adapters/commandtopic.md` / `eventtopic.md` contradict the framework's at-least-once idempotency doctrine (stated in the same pages' retry sections). Soften to "exactly-once publish deduplication, at-least-once processing".
- `@noDcbTag` (docs) vs `@noTag` (rules) — PPX accepts both; add an alias note in `reventless-ppx.md`.

**Style/terminology drift (batch-fixable):**
- npm vs pnpm: `running-tests.md`, `writing-unit-tests.md`, `component-testing-guide.md`, `troubleshooting/common-issues.md` (advises `npm ci`/package-lock — misleading in a pnpm repo), `rescript-monorepo-build-behaviour.md`, `ppx-binary-management.md` still say npm.
- "CloudWatch Events" (bodies) vs "EventBridge" (titles) in AWS adapter pages — pick EventBridge, note the old name once.
- Admonitions: docs-app uses 36; docs-infrastructure uses 1 and plain `>` blockquotes elsewhere — adopt admonitions.
- "local platform" (42×, app/tutorials) vs "Local provider" (13×, infra) — settle ("Local provider" = the package, "local platform" = the running instance) and state in the glossary.
- "read-model" hyphenated (64×) is the outlier vs "ReadModel"/"read model" — normalize prose.
- Heading hierarchy flat (`##` for everything) in `eventtopic.md`, `eventcollector.md` (also has a stray orphan `#` at line 110 and its SNS→SQS benefits list duplicated within the page), `querydb.md`, `queryengine.md`.
- Frontmatter noise: Hugo-style `date:`/`draft:` on older pages renders wrong staleness signals (2021/2024 dates on current pages); stale `sidebar_position` keys in docs-tutorials contradict the explicit sidebar. Drop both.
- Leftover editorial artifacts: `counter.md:493-497` "## Replacing the Old counter.md"; `eventlog.md:154` draft-note paragraph; `component-testing-guide.md:1070` "Last updated … (2024)".
- Typos/broken block: `rescript-syntax.md` (broken code block lines 198-203 missing `}`; "documtation", "meaningfull", "feasable"), `aggregate.md` ("declarataive").

**Verified clean:** DCB always "Dynamic Consistency Boundary" (0 hits for "Decision Causation"); 934× ```` ```rescript ````, 0× ```` ```res ````; no `docs/plans` links; no "Plan 0x"/stage leakage (all Phase/Stage hits are genuine runtime phases); all 73 cross-section route links resolve.

---

## 5. Commercial & internal-content leakage (must scrub)

The site is **near-clean** of commercial content — no console-web, paid tiers, pricing, or business-repo mentions. Remaining items:

1. `docs-app/mixed-source-automationslice.md:13` — "The motivating **commercial use case** is a platform-inspector automation…". Replace with the neutral AutoFulfill example already on the page.
2. `docs-app/concepts/directives.md:355` — documents the "New ExtensionPoint" scaffolding in the **`reventless-tools` repo** readers cannot obtain. Rephrase or remove. (Verify `@reventlessdev/reventless-vscode` in `given-when-then.md` §8 is actually published before keeping install instructions.)
3. `docs-app/dcb-usage.md:~881` — private `MEMORY.md` reference (also listed as critical error #10).
4. `docs-infrastructure/appsync-events-live-updates.md` — lists **reventless-ui repo internal file paths** (`src/live/EventsClient.res`, `AutoLive.res`, `LiveConnection.res`, `reventless-host-shell/src/App.res`) and pins internal releases; violates the no-UI-repo-internals rule. Replace with behavior-level statements. Also cites internal plan doc `realtime-change-descriptors.md`.
5. `docs-infrastructure/ui-fragments-deployment.md:127,177` — narrates sibling-repo checkout mechanics; cites internal plan doc `cloudfront-ui-fragments-core.md`.
6. `docs-infrastructure/aws-lambda-layer.md` — CI/CD workflow section (`AWS_LAYER_ACCESS_KEY_ID` secrets, `reventless-ci-layer-publisher` IAM user, SSM write path) is reventless-core's own release pipeline, not user docs.
7. `docs-infrastructure/deployment-guide.md:304` — "Sample-config discipline" blockquote about the team's own `app.reventless.dev` — internal contributor policy.
8. `docs-framework/cross-repo-dev-linking.md` — planning language ("Budget is shorter… File a separate per-repo plan") in public docs voice.
9. Bare internal plan/analysis file references in `lambda-deployment.md`, `appsync-events-live-updates.md` (GitHub `docs/analysis/*` links are borderline-acceptable since the repo is public; bare plan-file names are not).

---

## 6. Removal / relocation candidates

**Delete:**
- `docs-framework/get-started.md` — draft "moved" tombstone, unlinked (the section's only orphan).
- `docs-app/components/api.md` — actively wrong (manual-schema era); replace with a stub → `graphql-api-guide.md`.
- `docs-app/common-modules/config.md` — legacy Config; contradicts Platform pattern.
- `docs-app/writing-unit-tests.md` — superseded by `given-when-then.md` (merge Best Practices first).
- `packages/doc/CONTRIBUTING.md` — empty 5-line stub; fill (D2 conventions, sidebar-registration rule, section-audience rule) or delete.
- In-page: `counter.md` trailing editorial section; `readmodel.md` TODO block + legacy manual `idResolvers` half; `d2-diagrams.md` closing Quick-reference repeat; `internals/resources.md` "Questions Addressed" quiz; `internals/pulumi.md` "Why Pulumi" pitch + Conclusion; `internals/runtime.md` generic Lambda-tuning half; `lambda-deployment.md` §9 "Key Lessons" retrospective; `appsync-events-live-updates.md` war-story asides ("This is the part that bit us", historical notes).

**Relocate:**
- `docs-app/component-testing-guide.md` → docs-framework (framework-contributor mock/testing guide; fix `packages/reventless/tests/` paths on the way).
- `docs-app/concepts/aggregate-extension-connection.md` internals → `docs-framework/architecture/aggregate-extension-connection.md` (swap the inverted split).
- `docs-app/dcb-usage.md` back half (Dcb_Builder listings, registerHandler rationale, Open Issues) → rewritten `docs-framework/architecture/dcb.md`.
- `docs-infrastructure/dual-aws-provider.md` → framework internals (maintainer content: "file an issue against pulumi-aws-native", "reinstate a sleep"); leave one paragraph in `aws/architecture.md`.
- `docs-infrastructure/appsync-events-live-updates.md` — split: user-facing page keeps `*Stream/` opt-in, `liveReconnectRefetch`, debugging checklist; wire protocol + file maps → framework internals; "Zero-downtime handover" + expand/contract → `deployment-guide.md`.
- `docs-framework/output-types-in-reventless-spec.md` → `docs/analysis/` (it's an ADR: "Question → … → Conclusion"); fold the conclusion into `internals/resources.md`.
- `docs-framework/reventless-vscode-testing.md` (5k words, package lives in `reventless-tools`) → that repo, or delete.
- `docs-framework/forward-codegen-pipeline.md` + `reverse-codegen-pipeline.md` → `reventless-tools`, or fix every repo-relative path/link and mark them as documenting a sibling repo.
- `docs-framework/cross-repo-dev-linking.md` + rewritten `ppx-binary-management.md` → clearly-labeled Maintainers material (or repo CONTRIBUTING).
- `docs-app/aggregate-vs-dcb-decision-guide.md` "For AI Skills: Structured Decision Input" → the skill definition, not human docs.
- `docs-tutorials/ai-generated.md` → fold into `/app/ai-assisted/` (fix contradictions on the way) or rewrite around the real skills/MCP workflow.

**Merge (fold unique bits into owner, then delete):**
- `docs-app/concepts/dcb.md` (unless rewritten as the beginner DCB explainer — preferred), `concepts/statechangeslice-usage.md` (`@noDcbTag`, composite key → component page), `concepts/stateviewslice-usage.md` (projection-actions table → component page).

**Rename:**
- `docs-tutorials/get-started.md` → `overview` (it's a domain overview, not setup); `docs-infrastructure/get-started.md` → `scaffolding-a-provider` (with redirects). Resolves the 4-way `get-started` stem collision.
- `aws/index.md` "AWS Adapters" vs `local/index.md` "Local Provider" — align the two provider landing-page titles.

---

## 7. Missing topics

**High value (repeatedly hit as gaps across reviews):**
1. **Authorization guide (app-facing)** — per-command auth, `commandAuthorization`, `AllowAuthenticated` default, Cognito groups, `@index({group, authTable})` rules, LoginPage/users.yaml/dev users, X-User header. Today only fragments exist across identity.md, readmodel.md, and rules files. The framework is secure-by-default and the docs never explain the security model. (Framework-side twin: authorization/identity architecture page.)
2. **Local development workflow (app-facing)** — running reventless-local, the ports (4000/4001/3001/3002 — currently buried in guide §Split API Mode), `REVENTLESS_LOCAL_BACKEND` memory-vs-SQLite, seeding users, GraphiQL. Local is the primary dev loop and has no guide; `local/get-started.md` never mentions auth.
3. **Operations chapters (infrastructure)** — teardown/`pulumi destroy` ordering and non-empty-bucket failures; cost expectations for an idle/small deployment (raw material exists in lambda-deployment §4); monitoring (log groups, DLQ inspection/redrive — both queue pages say "inspect manually" without how); deploying-principal IAM + runtime least-privilege overview (`scheduledpublisher.md`'s `events:*` on `AllResources` needs a caveat).
4. **Schema evolution / event versioning (app-facing)** — adding fields, renaming variants, state-shape changes; expand→migrate→contract exists but is buried in appsync-events. EP protocol versioning is covered; nothing else is.

**Worth adding:**
5. Glossary repair + expansion — currently stale (`handle`/`apply`) and orphaned (almost never linked); missing tag, partition tag, fence, decision model, consumedEvent, projection, optimistic concurrency, GWT, sury/PPX. Link it where jargon first appears.
6. Adapter-set symmetry stubs — local StateTopic note (or "handled by the bus"), AWS SideEffectHandler page, EventLogSubscription page (only described inside appsync-events today).
7. **Postgres backend** — the new DCB EventLog Postgres runtime + change-feed relay has zero docs presence in any section; at minimum a status stub.
8. Framework-contributor pages: reventless-ppx internals (how to add an annotation, test harness), reventless-local internals (Backend split, `Local*` naming — currently only in `.claude/rules/`), local architecture page (AWS has one; local doesn't).
9. MCP API surface for apps (parallel of graphql-api-guide; one paragraph exists in ai-assisted/index).
10. `@@reventless.visibility` in `reventless-ppx.md`'s catalog (rules document it; the docs guide misses it).
11. Pagination/cursor semantics for Relay connections.
12. Tutorial-spine prerequisites box — event-sourcing vocabulary + `/app/rescript-syntax` link before the first ReScript snippet; no tutorial page links the syntax primer today.

---

## 8. Site-level housekeeping

- `docusaurus.config.js:165` `onBrokenLinks: "warn"` → `"throw"` for a public site.
- Four `editUrl`s point at `tree/main` (404 — see critical error #5).
- `packages/doc/README.md` — says published to reventless.dev (actual: docs.reventless.dev); says "four documentation instances" then lists five.
- Blog un-draft is a 5-file checklist (3 posts + navbar link + `indexBlog`) — add a comment listing all five; fix the Category claim in the third post before un-drafting.
- The hybrid tutorial (recommended spine) never shows `decide`/`evolve` code — add one real slice + aggregate walkthrough or explicit pointers into the aggregate/DCB pages' §1–5.
- `test-on-aws.md`: make `verify-subscriptions.mjs` read `pulumi stack output` instead of documenting hand-editing its config block.

---

## 9. Prioritized action plan

**P0 — factual errors on the entry path (small edits, big trust impact):**
1. Fix `@reventless/*` → `@reventlessdev/*` scope (3 files) and rewrite `docs-infrastructure/aws/get-started.md` + `local/get-started.md` against the current functor API and pnpm.
2. Fix the Category aggregate/DCB contradiction (`choosing-an-approach.md`, blog post 3).
3. Fix the `tree/main` link class (3 tutorial links + 4 editUrls); set `onBrokenLinks: "throw"`.
4. Add `pnpm install` + `pnpm run setup` to `run-locally.md` prerequisites; fix the setup-script cwd in `test-locally.md`.
5. Remove the `MEMORY.md` reference and fix line 32 in `dcb-usage.md`; delete `readmodel.md`'s TODO block; scrub the commercial/internal mentions (§5 items 1–2).

**P1 — stale-API pages that teach wrong code:**
6. Rewrite `docs-framework/architecture/dcb.md` against the current Spec/Behavior API (remove `DcbSpec`); move dcb-usage's internals appendix into it.
7. Replace/stub `components/api.md`, `common-modules/config.md`; refresh `commandgenerator.md`.
8. Retire `writing-unit-tests.md` into `given-when-then.md`; rewrite `running-tests.md` for app projects; purge `@glennsl/rescript-jest` references.
9. Fix `internals/messages.md`'s stale Reference/Examples halves; `ppx-binary-management.md`'s obsolete commit-the-binary workflow; transport guide's "not yet implemented" claim.
10. Fix the 5 wrong AWS-adapter front-matter titles and reconcile the event-delivery story (SNS→SQS vs DynamoDB Streams) against source.

**P2 — deduplication & layering:**
11. Fix the guide's internal contradictions (Aggregate→Delegate, EP filename, make signature), reconcile the 8 tutorial-drift points, then replace tutorial code dumps with excerpts + guide anchor links (bidirectional).
12. Unify `@index` syntax across the three guides; delete `@noApiVariants`.
13. Swap the aggregate-extension-connection split; retrofit older AWS adapter pages to the dcbeventlog template (querydb first); add adapter→component and component→local-adapter link edges.
14. Collapse the `concepts/` trio; give `@@reventless.async` one owner; dedupe layer/custom-domain content to their owner pages.
15. Split appsync-events-live-updates (user page / internals / deployment lifecycle); move dual-aws-provider, component-testing-guide, output-types, vscode-testing, codegen pages per §6.

**P3 — new content:**
16. Write the Authorization guide and the Local Development guide (highest-value gaps).
17. Add teardown/cost/monitoring/IAM ops chapters; repair + link the glossary; add the tutorial prerequisites box; Postgres-backend status stub.

---

*Full per-file verdict tables from the five review passes are preserved in the session transcripts; this document keeps only actionable findings. Counts: 156 pages read; 24 critical factual errors; 16 duplication clusters; ~30 removal/relocation candidates; 12 missing-topic areas.*
