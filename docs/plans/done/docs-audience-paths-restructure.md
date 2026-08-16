# Plan: Restructure the docs site around four audience paths

**Status**: Done (2026-08-16) — the restructure and the correctness work landed; the long tail moved to [Backlog/docs-remaining-gaps.md](../Backlog/docs-remaining-gaps.md). See [Execution status](#execution-status).
**Scope**: `packages/doc/` — information architecture, homepage, navbar, sidebars, and the content each audience path sees, **plus** the docs correctness/dedup/new-content backlog. This plan absorbs [docs-quality-improvements.md](./docs-quality-improvements.md) (now in `done/`, merged here as Phases R and E); the full findings behind those phases live in the analysis [docs-quality-review-2026-07.md](../../analysis/docs-quality-review-2026-07.md) — items reference its sections (§) rather than repeating evidence.

## Goal

Help **evaluators and app developers** understand quickly what Reventless is, how it helps them, and what its advantages are — without being confused by framework internals or by the implementation language. Internals remain available, but only on the contributor path.

Four audiences, four paths, strictly separated by how much they need to know:

| # | Audience | Question | Internals? | Language talk? |
|---|---|---|---|---|
| 1 | **Evaluator** | "What is Reventless? Could I use it for my development?" | none | none |
| 2 | **App developer — try it** | "How do I get the online-shop example running in my own AWS account?" | none | minimal (copy-paste level) |
| 3 | **App developer — build** | "How do I create my own app from scratch?" | only what's needed to write apps | specs vocabulary only, as-needed |
| 4 | **Contributor** | "How does the framework work, and how do I extend it?" | full | full |

## Current-state assessment

The site already has a four-section split (Tutorial / App Guide / Infrastructure / Contributing) plus homepage "Pick your path" cards — the skeleton is right. The problems are in what each path actually contains:

### P1 — There is no evaluator content, only a redirect into code

- The evaluator card on the homepage points to the Intro page and then straight into the **hybrid walkthrough** — 448 lines dominated by ReScript listings. An evaluator asking "should I use this?" is shown implementation code on page 3.
- The homepage hero and Intro lead with "**type-safe ReScript**" in the first sentence. For the evaluator this foregrounds exactly the fear we want to defuse ("a strange language I'd have to learn from scratch") before any benefit has been established.
- **The sovereignty/portability story is completely absent**: `grep -ri "sovereign|data center|on-premise" docs-* src` → zero hits. The two-deployment-options message (AWS serverless fast path now; sovereign cloud / own data center later by switching configuration, keeping data ownership) exists nowhere on the site, yet it is a core evaluator argument.
- Advantages over other approaches (vs. hand-built CRUD backends, vs. wiring queues/tables/APIs by hand) are implied but never laid out.
- The AI-assisted story exists (`/app/ai-assisted/`) but is buried at the bottom of the App Guide sidebar, invisible to an evaluator.

### P2 — "Run the example on AWS" is not a standalone path

- The tutorial spine forces the reading order *understand the code → run locally → deploy*. Deploying to your own AWS account (`deploy-to-aws.md`) is page 6 and assumes the walkthrough. Someone who just wants to *see it run* in their account has no direct path.
- The deploy page is good but has freshness bugs (see P5) and ends at CloudFront invalidation — there is no "what you can do with it now" payoff section (host-shell UI, live subscriptions, GraphQL API, MCP access, admin views).

### P3 — The app-developer path is buried under reference material and internals

- `docs-app/get-started.md` starts with language exposition (ReScript, Sury, PPX config) and manual `pnpm init` project assembly before the reader has built anything. The AI-assisted path (describe your domain → generated app) is not mentioned there at all.
- The App Guide sidebar interleaves the path with **framework-internal component pages** an app developer never touches directly: `commandtopic`, `commandgenerator`, `eventcollector`, `eventlog`, `dcbeventlog`, `eventtopic`, `eventmapper`, `heartbeat`, `counter`, `scheduler`, `querydb`, `api`. These describe plumbing the framework wires for you — reading them is confusing, not helpful, for path 3.
- The real "build your own app" material (`platform-and-plugin-guide.md`, 1,770 lines) is a single monolith hidden under *Guides → Build your own app*.

### P4 — Internals leak across sections

- Infrastructure section mixes app-operator content (deploy, custom domain, live updates) with provider-author content (adapter pattern, scaffolding a provider) and internals-grade adapter pages (13 local + 13 AWS adapter pages). Only the first group serves paths 2–3.
- App Guide "Concepts" contains pages at internals altitude (`aggregate-extension-connection` duplicated in docs-framework, `directives`).

### P5 — Freshness (spot-verified 2026-08-16)

The [2026-07 quality analysis](../../analysis/docs-quality-review-2026-07.md) found 24 critical factual errors, 16 duplication clusters, ~30 removal candidates, and 12 missing-topic areas; the fixes (now Phases R and E of this plan) are still essentially unexecuted. Re-verified samples:

- `deploy-to-aws.md` pins host-shell `3.0.0-alpha.28`; the example actually pins `3.0.0-alpha.75` — the doc drifted exactly as predicted; must become "check the pin in `platform-aws/package.json`".
- `choosing-an-approach.md:39-40` still says Category → aggregate; `hybrid-based.md` (and the shipped example) makes Category DCB and Customer the only aggregate.
- `docs-framework/get-started.md` is still a `draft: true` tombstone; blog still fully drafted.
- Features documented since July (ui-configuration, `@retired`, `@owner`, merged API) landed as per-feature pages, but recent runtime features (RuntimeExtension seam, query interception, role narrowing) have no user-facing docs page — verify coverage during Phase E below.

---

## Target information architecture

Navbar (order = audience funnel):

| Label | Route | Audience | Content |
|---|---|---|---|
| **Why Reventless** | `/why` (new, small) | 1 Evaluator | concepts, advantages, deployment options, AI story — prose + diagrams, zero code |
| **Try it** | `/tutorials` (restructured) | 2 | run the shop locally and in your own AWS account |
| **Build your app** | `/app` (restructured) | 3 | task-oriented spine + reference |
| **Infrastructure** | `/infrastructure` (trimmed) | 2+3 operators | deploy/operate guides; provider-author material moves to Contributing |
| **Contributing** | `/framework` | 4 | unchanged mission; absorbs internals evicted from other sections |

Homepage cards updated to the same four paths (the current three cards conflate paths 2 and 3).

### Path 1 — "Why Reventless" (new section, ~5 short pages)

New docs plugin instance `docs-why` → `/why`. Rules for every page here: **no code listings, no ReScript discussion, no internals, no component names beyond the concept level**. Neutral, factual tone — describe, don't sell hard.

1. **What is Reventless** — the programming model in plain language: your application is described by *specs* (what commands exist, what events they produce, what views users see) and *scenarios* (Given/When/Then examples that double as automated tests). The platform derives everything else: storage, APIs (GraphQL + MCP), a generated UI, and the cloud infrastructure. One source of truth, no glue code.
2. **What you provide, what you get** — the contract made concrete: you write domain specs + scenarios; you get a running system with full audit trail (event sourcing), live-updating read models, auto-generated admin/user UI, and infrastructure that scales to zero. A single d2 diagram (specs in → running system out). Mention that specs are written in a small, declarative vocabulary and that AI assistants generate and maintain them from natural-language domain descriptions — the language is a detail, not a prerequisite.
3. **How AI helps you build** — evaluator-level version of the AI-assisted story: describe your domain in your own words → complete, compilable application; scenarios act as guardrails so generated code is verified, not trusted; the built-in MCP server lets assistants operate the running app. Links to `/app/ai-assisted/` for the hands-on version.
4. **Deployment: fast now, sovereign later** — the two-options story, currently missing entirely:
   - **AWS serverless**: everything provisioned automatically; running in your account in under an hour; no servers to operate; pay-per-request, scales to zero.
   - **Sovereign cloud / own data center**: the business application is provider-independent *by construction* — the same app code runs against any provider package, selected by configuration; your data (the event log) is portable with you. **Message to convey**: a sovereign/on-premise production platform is **not shipping today**, but it is **firmly on the roadmap and actively being worked on** — the provider seam and the Postgres storage engine are the pieces already in place. State plainly: build on AWS serverless now; when the sovereign platform ships, your business app moves by switching configuration, not by rewriting.
5. **How it compares** — advantages in neutral terms: vs. hand-assembling serverless plumbing (queues/tables/functions/IAM by hand); vs. CRUD frameworks (no audit trail, read/write coupling, schema drift between layers); what you give up (event-sourced thinking is a shift; the ecosystem is young). An honest trade-off table builds more trust with evaluators than a pitch.

End of path: two buttons — "See it run" (path 2) and "Build your own" (path 3).

Sourcing: pages 1–2 distill `docs-app/index.md` + the homepage hero; page 3 distills `/app/ai-assisted/index.md`; page 4 is new (grounded in `docs-infrastructure/index.md` provider model + `local-persistence.md` + `postgres-aws-deployment.md` status notes); page 5 is new.

### Path 2 — "Try it" (restructure `docs-tutorials`)

Reorder the spine to *run first, understand later*, and make the AWS deploy self-contained:

1. `overview.md` (rename of `get-started.md`, with redirect) — what the online shop is, in domain terms only (keep the command/event tables; they are prose-level). Drop the "Implementations" deep-dive to a short pointer.
2. `run-locally.md` — as today (fix: add `pnpm install` + `pnpm run setup` prerequisites, R1.4).
3. `test-locally.md` — as today.
4. **`deploy-to-aws.md` — promoted and made standalone**:
   - *Preconditions* (already good): AWS account + IAM permissions, Pulumi CLI + account, Node/pnpm, GitHub Package Registry token. Add: expected cost footprint (serverless, scales to zero; rough idle cost ≈ $0) and region note.
   - *Steps*: as today (org rename, Cognito, pin check, platform → catalog → ordering). Fix the stale host-shell pin (R1.5) and remove any dependency on having read the walkthrough.
   - *New closing section* — **"What you have now"**: the host-shell UI on CloudFront (create products, place orders, watch live updates), the GraphQL API endpoint, the MCP endpoint for AI assistants, Cognito-backed auth, admin views, and how to tear it all down again (`pulumi destroy` order — pulls the teardown chapter forward from Phase E.4 because path 2 is exactly where people abandon experiments).
5. `test-on-aws.md` — as today.
6. **"Understand the code" category** (moved after the run/deploy pages): `choosing-an-approach.md` (fix the Category contradiction, R1.2), `hybrid-based.md`, and the alternates (`aggregate-based`, `dcb-based`, `ai-generated`). This is where ReScript first appears on this path — clearly labeled as optional depth.

### Path 3 — "Build your app" (restructure `docs-app`)

Split the sidebar into a **spine** (ordered, task-oriented, minimal) and **reference** (alphabetical, look-up):

**Spine:**
1. `get-started.md` — rewritten. Open with the two ways to start: **AI-assisted** (recommended: describe your domain, `/reventless-new` generates the project — promote `ai-assisted/getting-started.md` content here) and **manual scaffold** (the current pnpm/rescript.json material, compressed). Language exposition shrinks to one reassuring paragraph: "specs are written in a small declarative vocabulary; here is the 10-line shape of one; the [syntax reference](./rescript-syntax.md) exists when you need it."
2. **Model your domain** — Event-Storming-lite guidance + the aggregate-vs-DCB decision (promote `aggregate-vs-dcb-decision-guide.md` out of Guides).
3. **Write specs** — commands/events/state for aggregates and slices (extracted from `aggregates.md`, `dcb-slices.md`, and the relevant `platform-and-plugin-guide.md` chapters).
4. **Write scenarios** — GWT as the primary testing story (`given-when-then.md` promoted; `running-tests.md` rewritten for app projects, R2.5).
5. **Views and UI** — read models / state views + `ui-configuration.md`.
6. **Connect plugins** — extension points/extensions at usage level (`plugin-system.md`).
7. **Run and deploy** — local platform + pointer to path 2's AWS deploy and `/infrastructure` guides. Absorbs the local-development-guide material from Phase E (ports, backends, users.yaml, GraphiQL), pulling the Split-API-Mode material out of the platform-and-plugin-guide.

**Reference** (collapsed categories): Components — **only app-authored ones** (aggregate, statechangeslice, stateviewslice, readmodel, automationslice, in/outboundtranslationslice, extension, extensionpoint, task, plugin, sideeffecthandler); Common Modules; PPX annotation catalog (`reventless-ppx.md`); GraphQL API guide; seeding; querydb-key-design; mixed-source guides; ReScript syntax; troubleshooting; glossary.

**Evicted to Contributing** (with redirects): the infrastructure-component pages an app developer never writes (`commandtopic`, `commandgenerator`, `eventcollector`, `eventlog`, `dcbeventlog`, `eventtopic`, `eventmapper`, `heartbeat`, `counter`, `scheduler`, `querydb`, `api` — the last per R2.3 becomes a stub to the GraphQL guide first). Where an app-facing concept exists (e.g. `@@reventless.async` on commandtopic), keep that fragment in the PPX catalog or the spec chapters before moving the page.
`platform-and-plugin-guide.md` is progressively dissolved into spine chapters 3–7; until then it stays linked as the end-to-end deep guide.

### Path 4 — "Contributing" (`docs-framework`, mostly as-is)

- Keep the existing order (contributing → internals tour → extending). Internals stay here and *only* here.
- Absorb the pages evicted from App Guide (as an "Under the hood: runtime components" category) and Infrastructure's provider-author material (`adapter-pattern.md`, `get-started.md`/scaffolding-a-provider, the per-adapter reference pages can stay in `/infrastructure` but be linked from here — decide during implementation; default: leave adapter pages in place, move only the two authoring guides' sidebar entries).
- Delete the `get-started.md` tombstone (R3e).

### Homepage

- Hero: reframe subtitle/description around specs + scenarios + derived system + two deployment options; demote ReScript to a single mention alongside Pulumi/AWS ("built on" credits), not the opening claim.
- Four path cards matching the four sections; evaluator card → `/why`.

---

## Phasing

Each phase is independently landable; docs build green (`pnpm --filter ./packages/doc run build`) is the gate for every phase. Redirects (`@docusaurus/plugin-client-redirects`) required for every moved/renamed page.

| Phase | Theme | Size |
|---|---|---|
| A | Evaluator path: `docs-why` section (5 pages), homepage rework, navbar | new content, ~1 week of writing |
| B | Tutorials reorder + standalone AWS deploy page (incl. its R1 fixes + teardown) | mostly moves + 1 new section |
| C | App Guide spine/reference split + get-started rewrite + component-page eviction | largest; can land sidebar-first, then rewrite pages |
| D | Infrastructure/Contributing boundary + tombstone cleanup | small |
| R | Correctness backlog (merged from the quality plan): R1 factual fixes + scrub → R2 stale-API rewrites → R3 dedup/layering/moves → R4 consistency sweep | detailed below |
| E | New content (merged from the quality plan's Phase 5, minus items pulled into B/C) | 4–6 new pages |

Ordering notes:
- **A and B first** — they serve the goal (evaluators + triers) with the least effort and no dependency on the big rewrites.
- **R1 items that sit on paths 1–2** (host-shell pin, Category contradiction, setup steps, `tree/main` links) land inside Phase B, not separately.
- **R1–R2 must land before or interleaved with C** — the spine must not be assembled from factually wrong pages. R3 requires R2 (you can't point tutorials at guide anchors while the guide contradicts itself); parts of R3 are subsumed by C/D and are marked below.
- C is the long tail; the sidebar restructure (cheap, high-impact) can land before the page rewrites it motivates.
- E last, except the two items pulled forward (teardown → B; local-dev guide → C spine chapter 7).

**Verification gate for R and E:** any claim about current behavior must be verified against source (or by running the example), never against another doc page — doc-vs-doc reconciliation is how the current contradictions arose.

---

## Phase R — Correctness backlog (merged from docs-quality-improvements)

### R1 — Entry-path factual fixes + internal-reference scrub

Small edits with outsized trust impact; one commit (or two: fixes / scrub).

**Factual fixes:**
1. npm scope `@reventless/*` → `@reventlessdev/*` + real package names: `docs-infrastructure/aws/get-started.md:22`, `docs-infrastructure/local/get-started.md:18`, `docs-framework/internals/pulumi.md:105-106`. (Full rewrite of the two get-started pages is R2; this stops the broken install command now.)
2. Category contradiction: `docs-tutorials/choosing-an-approach.md:39-40` and `blog/2026-05-23-building-the-online-shop-end-to-end.md` — Category is DCB (verify once against `examples/online-shop-hybrid/catalog/src/Category/`), Customer is the aggregate. *(Lands in Phase B.)*
3. `tree/main` link class: 3 tutorial links (`hybrid-based.md:21`, `run-locally.md:14`, `test-locally.md:18`) + 4 `editUrl`s in `docusaurus.config.js` → derive from `docsVersion` or pin to `alpha`. Flip `onBrokenLinks` to `"throw"` (config line 165) in the same commit. *(Lands in Phase B.)*
4. `docs-tutorials/run-locally.md`: add `pnpm install` + `pnpm run setup` (users.yaml seed) to prerequisites; fix `test-locally.md`'s `node scripts/setup.mjs` cwd (repo root). *(Lands in Phase B.)*
5. `docs-tutorials/deploy-to-aws.md`: replace the hardcoded host-shell pin (doc says `alpha.28`; example is already at `alpha.75`) with "check the current pin in `platform-aws/package.json`". *(Lands in Phase B.)*
6. `docs-app/components/readmodel.md:219-226`: delete the four-`TODO` idResolvers block (superseded by `@resolves`/`@resolvesMany` docs).
7. `docs-app/dcb-usage.md`: remove the `MEMORY.md` reference (~line 881); fix the stale "one FIFO queue per plugin" intro at line 32.

**Internal-reference scrub (§5):**
8. `docs-app/mixed-source-automationslice.md:13`: replace the out-of-repo use-case mention — use the AutoFulfill example as motivation.
9. `docs-app/concepts/directives.md:355`: remove/rephrase the private-repo scaffolding reference; verify `@reventlessdev/reventless-vscode` (referenced in `given-when-then.md` §8) is published before keeping its install instructions.
10. `docs-infrastructure/appsync-events-live-updates.md`: strip UI-repo-internal file paths and internal plan-doc citations (behavior-level statements instead). Full split of the page is R3.
11. `docs-infrastructure/ui-fragments-deployment.md:127,177`: drop sibling-repo checkout narration + plan citation.
12. `docs-infrastructure/aws-lambda-layer.md`: remove the CI/CD internals (secrets, publisher IAM user, SSM write path).
13. `docs-infrastructure/deployment-guide.md:304`: remove the "Sample-config discipline" internal-policy blockquote.
14. Bare plan-file references in `lambda-deployment.md` / `appsync-events-live-updates.md`: remove or convert to public GitHub `docs/analysis/` links.

**Done when:** docs build green with `onBrokenLinks: "throw"`; `grep -rn "MEMORY.md\|tree/main" docs-* blog docusaurus.config.js` returns only intentional hits, and the §5 scrub greps from the analysis come back clean.

### R2 — Stale-API page rewrites

Pages that teach removed APIs. Each item: verify current behavior in source first, then rewrite. Roughly one commit per bullet group.

**DCB (framework side):**
1. Rewrite `docs-framework/architecture/dcb.md` against the current Spec/Behavior API: remove `Plugin.DcbSpec` (doesn't exist), `reduce`/`initialDecisionModel`/`decisionModel` → `initialState`/`evolve`/`decide`, PPX-injected tags, sync-default/async-FIFO queue model. Scope it to deploy-time wiring + design decisions (registerHandler vs makeHandler, serialization); open with a link to `/app/concepts/dcb`. Absorb the internals appendix currently duplicated in `docs-app/dcb-usage.md` (and delete it there).
2. Update `docs-framework/application-development-layers.md` to the current API + PPX conventions (`Product_Behavior.res`, `@@reventless.spec`), or move to docs-app and merge with the guide (decide during implementation; default: update in place, reframe as "how the framework enforces layer boundaries").

**Generated-API era (app side):**
3. `docs-app/components/api.md` → stub pointing at `graphql-api-guide.md` (or delete + redirect — Phase C evicts it anyway). `docs-app/common-modules/config.md` → delete or rewrite for the Platform pattern. `docs-app/components/commandgenerator.md` → refresh the stale halves (`init/apply/execute`, hand-written `mutationsSchema`).
4. `docs-app/graphql-api-guide.md:219`: delete `@noApiVariants` (nonexistent); document variant-level `@noApi` instead.

**Testing docs:**
5. Merge `docs-app/writing-unit-tests.md` Best Practices into `given-when-then.md`; delete the rest (or leave a legacy-helpers stub). Rewrite `running-tests.md` for app projects (pnpm, `reventless-gwt`), not the framework monorepo. Purge `@glennsl/rescript-jest` everywhere (`platform-and-plugin-guide.md:1491,1498`, `docs-framework/component-testing.md`, `component-testing-guide.md`, `rescript-namespaces-and-shadowing.md`) → `@reventlessdev/rescript-jest`. *(Feeds Phase C spine chapter 4.)*

**Framework internals:**
6. `docs-framework/internals/messages.md`: regenerate the Examples + Reference sections from `reventless-spec/src/types/Message.res`; fix the correlation rule to match `deriveMeta` (correlationId inherited, parent msgId → causationId); fix type-definition paths.
7. `docs-framework/ppx-binary-management.md`: rewrite around the current model (gitignored binaries, republish distribution, local `ppx-osx.exe` fallback) at ~30% of current length, or fold into contributing/maintainers material.
8. `docs-framework/transport-adapter-guide.md`: fix "`QueryDb_Callback` not yet implemented" (it exists, with `queryInterceptorHook`).
9. `docs-framework/graphql-schema-debugging.md`: fix `examples/dcb/example-dcb` paths; delete or rebuild the dangling `DebugSchema.res` section.

**Infrastructure:**
10. Rewrite `docs-infrastructure/aws/get-started.md` end-to-end (functor Plugin API, `-aws` package structure with `Main.res`, pnpm, layer section shrunk to a link) and refresh `local/get-started.md` (+ mention users.yaml/auth). Fix `local-persistence.md` (`ReventlessLocal.Platform.MakeWithConfig`, five→six surfaces), `local/index.md` persistence row, `local/adapters/task.md` storage claim.
11. Fix the 5 wrong front-matter titles in `aws/adapters/` (task, queryengine, commandgenerator, heartbeat, scheduledpublisher) and settle CloudWatch Events → EventBridge naming.
12. **Reconcile the event-delivery story** (adapter pages' SNS→SQS-FIFO vs lambda-deployment §8's `DynamoDbStream` defaults): determine the actual default from `reventless-aws` source, then make `eventtopic.md`, `eventcollector.md`, `lambda-deployment.md`, and `dcbeventlog.md` tell one story. Soften "exactly-once" claims to "exactly-once publish dedup, at-least-once processing".

**Tutorials:**
13. Fix stale snippets: `aggregate-based.md` §6 `Main.res` (`CatalogMaker`/`uiBundleUrl` → the shipped 11-line form), `hybrid-based.md:383` `make(~uiBundleUrl=?)` → `make = ()`. Same signature sweep across component pages (`plugin.md`, `extension.md`, `automationslice.md`, `task.md`).
14. `docs-tutorials/ai-generated.md`: fix the 24-hour/immediate-ship contradiction and phantom port 4002; name and link the real tooling (`/app/ai-assisted/`, MCP) — or fold the page into `/app/ai-assisted/` (R3 decides).

**Done when:** no page documents an API absent from `reventless/*/src` (spot-verified per item); build green.

### R3 — Deduplication, layering, moves/removals

Requires R2 (canonical pages correct). Sub-phases land as independent commits; redirects for every moved/renamed page. Items marked *(→ C)* / *(→ D)* are executed as part of those phases rather than separately.

**R3a — Guide ⇄ tutorials (§3 row 2):**
- Fix `platform-and-plugin-guide.md` internal contradictions first: `module Aggregate` → `module Delegate` (+ `extension.md` module type), EP filename → `Products_ExtensionPoint.res` (underscore, matches rules), `make = ()` signature.
- Reconcile the 8 drift points (Behavior state shape, read-model `productId` field, EP/Extension style, `heartbeatInterval`, `Main.res` shapes, command names) — guide wins unless the tutorial matches shipped example code; **the shipped `examples/` are the source of truth**.
- Then: tutorials keep narrative + domain tables + short excerpts, deep-link into guide anchors; dedupe the near-verbatim EP/Extension/Main.res sections between `aggregate-based.md` and `dcb-based.md` (link like `hybrid-based.md` does); stop repeating the domain tables (own them in the tutorials overview page). *(Coordinates with Phase B's reorder.)*
- Add one real slice + aggregate code walkthrough to `hybrid-based.md` (or explicit §-pointers into the other two) — the recommended spine currently never shows `decide`/`evolve`.
- Cross-link `choosing-an-approach.md` ↔ `aggregate-vs-dcb-decision-guide.md`.

**R3b — DCB cluster (§3 row 1):**
- `concepts/dcb.md` → rewrite as the beginner "What is a Dynamic Consistency Boundary?" explainer (tag, partition, fence, decision model defined before use — currently nothing defines them).
- Collapse `concepts/statechangeslice-usage.md` / `concepts/stateviewslice-usage.md` into their component pages (keep `@noDcbTag`+composite-key bits and the projection-actions table).
- `dcb-usage.md` scoped to tags/partitioning/`@crossPartition` (internals already moved in R2.1).
- Give `@@reventless.async` one owner; with Phase C evicting `components/commandtopic.md`, the owner becomes the PPX catalog (`reventless-ppx.md`) — shrink the other ~5 explanations to a sentence + link.

**R3c — Annotation syntax (§4):**
- Unify `@index`/`@compositeId`/`@resolves` syntax on `reventless-ppx.md`'s record/string forms (verified against PPX source) across `querydb-key-design-guide.md` (drop its own annotation reference) and `graphql-api-guide.md` §6.4. Add the `@noTag`/`@noDcbTag` alias note and `@@reventless.visibility` to the ppx catalog.

**R3d — Component ⇄ adapter pages (§3 row 6):**
- Retrofit older `aws/adapters/*` to the `dcbeventlog.md` template (concept delegated, physical layout/IAM/config kept, ~40–50% shorter): `querydb.md` first, then `commandtopic.md`, `task.md`, `eventcollector.md`, `queryengine.md`, `commandgenerator.md` (drop the GraphQL-vs-REST filler), `heartbeat.md`, `counter.md`. Fix `eventcollector.md`'s duplicated benefits list + stray `#` (line 110) and the flat heading hierarchies.
- Add the missing link edges: adapter → component back-links, component → local-adapter links.

**R3e — Swaps, splits, moves, deletions (§6):**
- Swap `aggregate-extension-connection` content: `Plugin_Helpers` walkthrough → framework page; app page becomes usage-level model + diagram + link. *(→ C/D)*
- Split `appsync-events-live-updates.md`: user page (Stream folders, `liveReconnectRefetch`, debugging checklist) stays; wire protocol/file maps → framework internals; zero-downtime handover + expand/contract → `deployment-guide.md`. Cut war-story asides.
- Move: `component-testing-guide.md` → docs-framework (fix stale paths; framework `component-testing.md` keeps two-layer architecture only, drops the per-file test index); `dual-aws-provider.md` → framework internals (one paragraph stays in `aws/architecture.md`); `output-types-in-reventless-spec.md` → `docs/analysis/` (conclusion folded into `internals/resources.md`). *(→ D)*
- Relocate or fix moved-package pages: `reventless-vscode-testing.md`, `forward-codegen-pipeline.md`, `reverse-codegen-pipeline.md` — clearly mark as sibling-repo docs and fix every path/link (incl. the dead `spec-implementation-split.md` ref), or relocate out of this site.
- `cross-repo-dev-linking.md` + `ppx-binary-management.md` → labeled Maintainers grouping; strip planning language.
- Delete: `docs-framework/get-started.md` (draft tombstone) *(→ D)*, `counter.md` trailing editorial section, `d2-diagrams.md` closing quick-reference repeat, "For AI Skills" section of `aggregate-vs-dcb-decision-guide.md` (→ skill definition).
- Dedupe to owners: lambda-layer content → `aws-lambda-layer.md`; custom-domain content → `custom-domain.md`; adapter-pattern's stale "InMemory Adapters" section → link `local/index.md`; workspace-link mechanics → `cross-repo-dev-linking.md`; mixed-source ReadModel → `mixed-source-readmodel.md`.
- Rename (with redirects): `docs-tutorials/get-started.md` → `overview.md` *(→ B)*; `docs-infrastructure/get-started.md` → `scaffolding-a-provider.md` *(→ D)*. Align `aws/index.md` / `local/index.md` titles.
- `ai-generated.md`: execute the R2.14 decision (fold vs rewrite).

**Done when:** each §3 duplication cluster has one owner; every moved page has a redirect; build green with `onBrokenLinks: "throw"`.

### R4 — Consistency sweep + housekeeping

Mechanical batch, mostly grep-driven; one or two commits.

1. npm → pnpm sweep (`troubleshooting/common-issues.md` incl. the npm-ci advice, `rescript-monorepo-build-behaviour.md`, remaining stragglers).
2. Frontmatter cleanup: drop Hugo-style `date:`/`draft:` from old pages (wrong staleness signals), drop stale `sidebar_position` keys in docs-tutorials, fix title-vs-H1 mismatches.
3. Admonitions in docs-infrastructure (replace `>` callouts); normalize prose "read-model" → "read model"; settle "Local provider" (package) vs "local platform" (running instance) and record it in the glossary.
4. Typos + broken block: `rescript-syntax.md` (lines 198-203 missing `}`, "documtation", "meaningfull", "feasable"), `aggregate.md` ("declarataive"), `eventlog.md:154` draft paragraph, `component-testing-guide.md:1070` "Last updated (2024)".
5. Trim AI-filler in framework internals: `resources.md` (~50%), `runtime.md` (drop generic Lambda-tuning half), `pulumi.md` (drop "Why Pulumi" + Conclusion) — keep the internals tour at one altitude. Cut `lambda-deployment.md` §9 "Key Lessons" retrospective.
6. Site housekeeping: `packages/doc/README.md` (docs.reventless.dev, five sections — now six with `/why`), fill or delete the empty `packages/doc/CONTRIBUTING.md`, add the 5-file blog un-draft checklist comment.

**Done when:** the greps in §4 of the analysis come back clean (or intentional); build green.

---

## Phase E — New content (merged from the quality plan's Phase 5)

Highest-value gaps (§7), roughly priority-ordered; each is its own commit + sidebar entry. Two original items are pulled forward and are **not** repeated here: the teardown chapter (→ Phase B's "What you have now" section) and the local development guide (→ Phase C spine chapter 7).

1. **Authorization guide** (docs-app): AllowAuthenticated default, per-command auth, `commandAuthorization`, Cognito groups, `@index({group, authTable})`, LoginPage/users.yaml/defaultUser/X-User dev flow. (Framework-side architecture twin optional, can be a follow-up.)
2. **Glossary repair**: fix `handle`/`apply` → `decide`/`evolve`, spec-file naming; add DCB vocabulary (tag, partition tag, fence, decision model, consumedEvent), projection, optimistic concurrency, GWT, sury/PPX, Local provider/platform; link it from pages where jargon first appears. Add the tutorial-spine prerequisites box (event-sourcing vocab + `/app/rescript-syntax` link).
3. **Ops chapters** (docs-infrastructure): cost expectations (from lambda-deployment §4 material), monitoring/DLQ inspection + redrive, deploying-principal IAM + least-privilege overview (incl. the `events:*` caveat).
4. **Symmetry stubs**: local StateTopic note, AWS SideEffectHandler page, EventLogSubscription page; **Postgres backend status stub** (the DCB EventLog Postgres runtime + change-feed relay currently invisible — also referenced by the `/why` sovereignty page, Phase A).
5. **Recent-feature coverage check** (new since the July analysis): verify RuntimeExtension seam, query interception, and role narrowing have user-facing docs where an app developer or operator meets them; write the missing pages or fold into existing guides.
6. Backlog candidates (move to `Backlog/` if not tackled here): schema-evolution/event-versioning guide, MCP API surface page, pagination/cursor semantics, reventless-ppx internals page, reventless-local internals page, local architecture page.

**Done when:** items 1–5 published and linked from the relevant sidebars/pages; item 6 triaged into `docs/plans/Backlog/`.

---

## Verification

- Build green with `onBrokenLinks: "throw"` from Phase A on.
- **Path walkthroughs**: after each phase, follow the affected path start-to-finish as its persona — evaluator path must contain zero code blocks and zero mentions of framework-internal components; path 2's deploy page must work from a fresh clone with only its stated preconditions (re-run against a real AWS account once, per the create-path verification practice).
- Every factual claim touched is verified against `reventless/*/src` or the shipped `examples/`, never against another doc page.
- `grep -ri "sovereign" packages/doc/docs-why` non-empty after Phase A; `grep -rn "alpha\.[0-9]" docs-tutorials` returns no hardcoded package pins after Phase B.

## Execution status

### Landed

- **Phase A** — `docs-why` section (5 pages) at `/why`, navbar reordered to the
  audience funnel, homepage hero + four path cards, `onBrokenLinks` and
  `onBrokenAnchors` set to `throw` (the two pre-existing offenders fixed).
- **Phase B** — tutorials reordered to run → test → deploy → test-on-AWS →
  "Understand the code"; `get-started.md` → `overview.md` with a redirect
  (`@docusaurus/plugin-client-redirects` added); deploy page made self-contained
  with cost footprint, "what you have now", and teardown. R1.2–R1.5 landed here,
  plus a full refresh of the overview's command/event tables against the shipped
  example (they were missing eight commands and named three that do not exist).
- **Phase C** — App Guide split into spine + Reference; 11 infrastructure
  component pages evicted to `docs-framework/runtime-components/` with
  redirects; `components/api.md` deleted → redirect to the GraphQL guide;
  `get-started.md` rewritten (AI-assisted first, manual scaffold second);
  new `local-development.md` ("Run and deploy"); `running-tests.md` rewritten
  for app projects.
- **Phase D** — `docs-infrastructure/get-started.md` → `scaffolding-a-provider.md`
  in a "Writing a provider" group linked from Contributing;
  `component-testing-guide.md` → docs-framework; `dual-aws-provider.md` →
  framework internals; `output-types-in-reventless-spec.md` → `docs/analysis/`
  with its conclusion folded into `internals/resources.md`; framework
  `get-started.md` tombstone deleted.
- **R1** — all factual fixes and the internal-reference scrub. Additionally:
  `forward-codegen-pipeline.md`, `reverse-codegen-pipeline.md`, and
  `reventless-vscode-testing.md` moved to `docs/guides/` — they document a
  package that is neither in this tree nor published in either registry.
- **R2** — DCB architecture page rewritten against the real Spec/Behavior API
  (and the duplicated internals removed from `dcb-usage.md`); `@noApiVariants` →
  per-variant `@noApi`; query interceptor un-marked as planned; message
  correlation rule corrected; `@glennsl/rescript-jest` purged; `~uiBundleUrl` /
  Maker-module snippets refreshed; three wrong adapter titles; schema-debugging
  paths; EventBridge naming settled; event-delivery story reconciled to the real
  default (DynamoDB Streams); exactly-once claims softened; local provider
  `MakeWithConfig` + split-API default corrected.
- **R4** — npm → pnpm, Hugo frontmatter, typos, the unclosed code block, "read
  model" normalisation, README + CONTRIBUTING rewritten.
- **E** — authorization guide (new), glossary repaired and expanded with the DCB
  vocabulary, `concepts/dcb.md` rewritten as the beginner explainer,
  `postgres-status.md` (new, referenced from `/why`).

### Not yet done

Moved to [Backlog/docs-remaining-gaps.md](../Backlog/docs-remaining-gaps.md):
three page rewrites (application-development-layers, ppx-binary-management,
commandgenerator), the guide ⇄ tutorial drift reconciliation, annotation-syntax
unification, the AWS adapter-page retrofits, the live-updates page split, the
remaining dedup-to-owner moves, internals trimming, and five new-content items
(symmetry stubs, schema evolution, MCP surface, pagination semantics,
contributor internals pages).

Also not done: **path 2 verified against a real AWS account**. The deploy page's
steps were checked against the shipped stack configuration and source, not by
running them.

## Out of scope

- Blog un-drafting itself (separate decision; R1 fixes its factual error, R4 adds the checklist).
- Docs for anything outside this repo's published packages — explicitly excluded; R1 removes the existing internal-reference leakage.
- UI-repo documentation.
