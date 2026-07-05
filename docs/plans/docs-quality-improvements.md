# Plan: Docs Site Quality Improvements

**Status**: Proposed — derived from analysis [docs-quality-review-2026-07.md](../analysis/docs-quality-review-2026-07.md) (2026-07-05)
**Nature**: umbrella roadmap over the docs site (`packages/doc/`). The analysis holds the full findings (24 critical errors, 16 duplication clusters, ~30 removal candidates, 12 missing-topic areas); this plan sequences them into commit-sized phases. Detail lives in the analysis — items below reference its sections (§) rather than repeating evidence.

## Phasing rationale

Order = trust-destroying factual errors on the newcomer path → pages that teach removed APIs → deduplication/layering (which requires the canonical pages to be correct first) → mechanical consistency sweeps → new content. Scrubbing commercial/internal mentions is part of Phase 1 because it is small and non-negotiable. Deduplication (Phase 3) must come *after* the stale-API rewrites (Phase 2): you can't point tutorials at guide anchors while the guide still contradicts itself.

| Phase | Theme | Analysis ref | Size | Status |
|---|---|---|---|---|
| 1 | Entry-path factual fixes + commercial/internal scrub | §2 #1–5,10,16–18; §5 | ~15 small edits | open |
| 2 | Stale-API page rewrites | §2 #3,6–9,11–15,19–24 | ~12 pages | open |
| 3 | Deduplication, layering, moves/removals | §3, §6 | large | open |
| 4 | Consistency sweep + site housekeeping | §4, §8 | mechanical batch | open |
| 5 | New content | §7 | 4–6 new pages | open |

**Verification gate (applies to every phase):** `pnpm --filter ./packages/doc run build` green with `onBrokenLinks: "throw"` (flipped in Phase 1), plus spot-check of changed pages in `pnpm run start`. Any claim about current behavior fixed in Phases 1–2 must be verified against source (or by running the example), not against another doc page — doc-vs-doc reconciliation is how the current contradictions arose.

---

## Phase 1 — Entry-path factual fixes + scrub

Small edits with outsized trust impact; one commit (or two: fixes / scrub).

**Factual fixes:**
1. npm scope `@reventless/*` → `@reventlessdev/*` + real package names: `docs-infrastructure/aws/get-started.md:22`, `docs-infrastructure/local/get-started.md:18`, `docs-framework/internals/pulumi.md:105-106`. (Full rewrite of the two get-started pages is Phase 2; this stops the broken install command now.)
2. Category contradiction: `docs-tutorials/choosing-an-approach.md:39-40` and `blog/2026-05-23-building-the-online-shop-end-to-end.md` — Category is DCB (verify once against `examples/online-shop-hybrid/catalog/src/Category/`), Customer is the aggregate.
3. `tree/main` link class: 3 tutorial links (`hybrid-based.md:21`, `run-locally.md:14`, `test-locally.md:18`) + 4 `editUrl`s in `docusaurus.config.js` → derive from `docsVersion` or pin to `alpha`. Flip `onBrokenLinks` to `"throw"` (config line 165) in the same commit.
4. `docs-tutorials/run-locally.md`: add `pnpm install` + `pnpm run setup` (users.yaml seed) to prerequisites; fix `test-locally.md`'s `node scripts/setup.mjs` cwd (repo root).
5. `docs-tutorials/deploy-to-aws.md`: replace hardcoded host-shell pin `alpha.28` with "check the current pin in `platform-aws/package.json`".
6. `docs-app/components/readmodel.md:219-226`: delete the four-`TODO` idResolvers block (superseded by `@resolves`/`@resolvesMany` docs).
7. `docs-app/dcb-usage.md`: remove the `MEMORY.md` reference (~line 881); fix the stale "one FIFO queue per plugin" intro at line 32.

**Commercial/internal scrub (§5):**
8. `docs-app/mixed-source-automationslice.md:13`: drop "commercial use case / platform-inspector" — use the AutoFulfill example as motivation.
9. `docs-app/concepts/directives.md:355`: remove/rephrase the `reventless-tools` scaffolding reference; verify `@reventlessdev/reventless-vscode` (referenced in `given-when-then.md` §8) is published before keeping its install instructions.
10. `docs-infrastructure/appsync-events-live-updates.md`: strip reventless-ui repo-internal file paths and internal plan-doc citations (behavior-level statements instead). Full split of the page is Phase 3.
11. `docs-infrastructure/ui-fragments-deployment.md:127,177`: drop sibling-repo checkout narration + `cloudfront-ui-fragments-core.md` plan citation.
12. `docs-infrastructure/aws-lambda-layer.md`: remove the CI/CD internals (secrets, `reventless-ci-layer-publisher` IAM user, SSM write path).
13. `docs-infrastructure/deployment-guide.md:304`: remove the "Sample-config discipline" internal-policy blockquote.
14. Bare plan-file references in `lambda-deployment.md` / `appsync-events-live-updates.md`: remove or convert to public GitHub `docs/analysis/` links.

**Done when:** docs build green with `onBrokenLinks: "throw"`; `grep -rn "MEMORY.md\|commercial\|reventless-tools\|tree/main" docs-* blog docusaurus.config.js` returns only intentional hits.

## Phase 2 — Stale-API page rewrites

Pages that teach removed APIs. Each item: verify current behavior in source first, then rewrite. Roughly one commit per bullet group.

**DCB (framework side):**
1. Rewrite `docs-framework/architecture/dcb.md` against the current Spec/Behavior API: remove `Plugin.DcbSpec` (doesn't exist), `reduce`/`initialDecisionModel`/`decisionModel` → `initialState`/`evolve`/`decide`, PPX-injected tags, sync-default/async-FIFO queue model. Scope it to deploy-time wiring + design decisions (registerHandler vs makeHandler, serialization); open with a link to `/app/concepts/dcb`. Absorb the internals appendix currently duplicated in `docs-app/dcb-usage.md` (and delete it there).
2. Update `docs-framework/application-development-layers.md` to the current API + PPX conventions (`Product_Behavior.res`, `@@reventless.spec`), or move to docs-app and merge with the guide (decide during implementation; default: update in place, reframe as "how the framework enforces layer boundaries").

**Generated-API era (app side):**
3. `docs-app/components/api.md` → stub pointing at `graphql-api-guide.md` (or delete + redirect). `docs-app/common-modules/config.md` → delete or rewrite for the Platform pattern. `docs-app/components/commandgenerator.md` → refresh the stale halves (`init/apply/execute`, hand-written `mutationsSchema`).
4. `docs-app/graphql-api-guide.md:219`: delete `@noApiVariants` (nonexistent); document variant-level `@noApi` instead.

**Testing docs:**
5. Merge `docs-app/writing-unit-tests.md` Best Practices into `given-when-then.md`; delete the rest (or leave a legacy-helpers stub). Rewrite `running-tests.md` for app projects (pnpm, `reventless-gwt`), not the framework monorepo. Purge `@glennsl/rescript-jest` everywhere (`platform-and-plugin-guide.md:1491,1498`, `docs-framework/component-testing.md`, `component-testing-guide.md`, `rescript-namespaces-and-shadowing.md`) → `@reventlessdev/rescript-jest`.

**Framework internals:**
6. `docs-framework/internals/messages.md`: regenerate the Examples + Reference sections from `reventless-spec/src/types/Message.res`; fix the correlation rule to match `deriveMeta` (correlationId inherited, parent msgId → causationId); fix type-definition paths.
7. `docs-framework/ppx-binary-management.md`: rewrite around the current model (gitignored binaries, republish distribution, local `ppx-osx.exe` fallback) at ~30% of current length, or fold into contributing/maintainers material.
8. `docs-framework/transport-adapter-guide.md`: fix "`QueryDb_Callback` not yet implemented" (it exists, with `queryInterceptorHook`).
9. `docs-framework/graphql-schema-debugging.md`: fix `examples/dcb/example-dcb` paths; delete or rebuild the dangling `DebugSchema.res` section.

**Infrastructure:**
10. Rewrite `docs-infrastructure/aws/get-started.md` end-to-end (functor Plugin API, `-aws` package structure with `Main.res`, pnpm, layer section shrunk to a link) and refresh `local/get-started.md` (+ mention users.yaml/auth — full local guide is Phase 5). Fix `local-persistence.md` (`ReventlessLocal.Platform.MakeWithConfig`, five→six surfaces), `local/index.md` persistence row, `local/adapters/task.md` storage claim.
11. Fix the 5 wrong front-matter titles in `aws/adapters/` (task, queryengine, commandgenerator, heartbeat, scheduledpublisher) and settle CloudWatch Events → EventBridge naming.
12. **Reconcile the event-delivery story** (adapter pages' SNS→SQS-FIFO vs lambda-deployment §8's `DynamoDbStream` defaults): determine the actual default from `reventless-aws` source, then make `eventtopic.md`, `eventcollector.md`, `lambda-deployment.md`, and `dcbeventlog.md` tell one story. Soften "exactly-once" claims to "exactly-once publish dedup, at-least-once processing".

**Tutorials:**
13. Fix stale snippets: `aggregate-based.md` §6 `Main.res` (`CatalogMaker`/`uiBundleUrl` → the shipped 11-line form), `hybrid-based.md:383` `make(~uiBundleUrl=?)` → `make = ()`. Same signature sweep across component pages (`plugin.md`, `extension.md`, `automationslice.md`, `task.md`).
14. `docs-tutorials/ai-generated.md`: fix the 24-hour/immediate-ship contradiction and phantom port 4002; name and link the real tooling (`/app/ai-assisted/`, MCP) — or fold the page into `/app/ai-assisted/` (Phase 3 decides).

**Done when:** no page documents an API absent from `reventless/*/src` (spot-verified per item); build green.

## Phase 3 — Deduplication, layering, moves/removals

Requires Phase 2 (canonical pages correct). Sub-phases can land as independent commits; Docusaurus redirects (`@docusaurus/plugin-client-redirects` is already available — verify) for every moved/renamed page.

**3a — Guide ⇄ tutorials (§3 row 2):**
- Fix `platform-and-plugin-guide.md` internal contradictions first: `module Aggregate` → `module Delegate` (+ `extension.md` module type), EP filename → `Products_ExtensionPoint.res` (underscore, matches rules), `make = ()` signature.
- Reconcile the 8 drift points (Behavior state shape, read-model `productId` field, EP/Extension style, `heartbeatInterval`, `Main.res` shapes, command names) — guide wins unless the tutorial matches shipped example code; **the shipped `examples/` are the source of truth**.
- Then: tutorials keep narrative + domain tables + short excerpts, deep-link into guide anchors; dedupe the near-verbatim EP/Extension/Main.res sections between `aggregate-based.md` and `dcb-based.md` (link like `hybrid-based.md` does); stop repeating the domain tables (own them in the tutorials overview page).
- Add one real slice + aggregate code walkthrough to `hybrid-based.md` (or explicit §-pointers into the other two) — the recommended spine currently never shows `decide`/`evolve`.
- Cross-link `choosing-an-approach.md` ↔ `aggregate-vs-dcb-decision-guide.md`.

**3b — DCB cluster (§3 row 1):**
- `concepts/dcb.md` → rewrite as the beginner "What is a Dynamic Consistency Boundary?" explainer (tag, partition, fence, decision model defined before use — currently nothing defines them).
- Collapse `concepts/statechangeslice-usage.md` / `concepts/stateviewslice-usage.md` into their component pages (keep `@noDcbTag`+composite-key bits and the projection-actions table).
- `dcb-usage.md` scoped to tags/partitioning/`@crossPartition` (internals already moved in Phase 2.1).
- Give `@@reventless.async` one owner (`components/commandtopic.md#sync-vs-async`); shrink the other ~5 explanations to a sentence + link.

**3c — Annotation syntax (§4):**
- Unify `@index`/`@compositeId`/`@resolves` syntax on `reventless-ppx.md`'s record/string forms (verified against PPX source) across `querydb-key-design-guide.md` (drop its own annotation reference) and `graphql-api-guide.md` §6.4. Add the `@noTag`/`@noDcbTag` alias note and `@@reventless.visibility` to the ppx catalog.

**3d — Component ⇄ adapter pages (§3 row 6):**
- Retrofit older `aws/adapters/*` to the `dcbeventlog.md` template (concept delegated, physical layout/IAM/config kept, ~40–50% shorter): `querydb.md` first, then `commandtopic.md`, `task.md`, `eventcollector.md`, `queryengine.md`, `commandgenerator.md` (drop the GraphQL-vs-REST filler), `heartbeat.md`, `counter.md`. Fix `eventcollector.md`'s duplicated benefits list + stray `#` (line 110) and the flat heading hierarchies.
- Add the missing link edges: adapter → component back-links, component → local-adapter links.

**3e — Swaps, splits, moves, deletions (§6):**
- Swap `aggregate-extension-connection` content: `Plugin_Helpers` walkthrough → framework page; app page becomes usage-level model + diagram + link.
- Split `appsync-events-live-updates.md`: user page (Stream folders, `liveReconnectRefetch`, debugging checklist) stays; wire protocol/file maps → framework internals; zero-downtime handover + expand/contract → `deployment-guide.md`. Cut war-story asides.
- Move: `component-testing-guide.md` → docs-framework (fix stale paths; framework `component-testing.md` keeps two-layer architecture only, drops the per-file test index); `dual-aws-provider.md` → framework internals (one paragraph stays in `aws/architecture.md`); `output-types-in-reventless-spec.md` → `docs/analysis/` (conclusion folded into `internals/resources.md`).
- Relocate or fix moved-package pages: `reventless-vscode-testing.md`, `forward-codegen-pipeline.md`, `reverse-codegen-pipeline.md` → `reventless-tools` repo (or clearly mark as sibling-repo docs and fix every path/link, incl. the dead `spec-implementation-split.md` ref).
- `cross-repo-dev-linking.md` + `ppx-binary-management.md` → labeled Maintainers grouping; strip planning language.
- Delete: `docs-framework/get-started.md` (draft tombstone), `counter.md` trailing editorial section, `d2-diagrams.md` closing quick-reference repeat, "For AI Skills" section of `aggregate-vs-dcb-decision-guide.md` (→ skill definition).
- Dedupe to owners: lambda-layer content → `aws-lambda-layer.md`; custom-domain content → `custom-domain.md`; adapter-pattern's stale "InMemory Adapters" section → link `local/index.md`; workspace-link mechanics → `cross-repo-dev-linking.md`; mixed-source ReadModel → `mixed-source-readmodel.md`.
- Rename (with redirects): `docs-tutorials/get-started.md` → `overview.md`; `docs-infrastructure/get-started.md` → `scaffolding-a-provider.md`. Align `aws/index.md` / `local/index.md` titles.
- `ai-generated.md`: execute the Phase 2.14 decision (fold vs rewrite).

**Done when:** each §3 duplication cluster has one owner; every moved page has a redirect; build green with `onBrokenLinks: "throw"`.

## Phase 4 — Consistency sweep + housekeeping

Mechanical batch, mostly grep-driven; one or two commits.

1. npm → pnpm sweep (`troubleshooting/common-issues.md` incl. the npm-ci advice, `rescript-monorepo-build-behaviour.md`, remaining stragglers).
2. Frontmatter cleanup: drop Hugo-style `date:`/`draft:` from old pages (wrong staleness signals), drop stale `sidebar_position` keys in docs-tutorials, fix title-vs-H1 mismatches.
3. Admonitions in docs-infrastructure (replace `>` callouts); normalize prose "read-model" → "read model"; settle "Local provider" (package) vs "local platform" (running instance) and record it in the glossary.
4. Typos + broken block: `rescript-syntax.md` (lines 198-203 missing `}`, "documtation", "meaningfull", "feasable"), `aggregate.md` ("declarataive"), `eventlog.md:154` draft paragraph, `component-testing-guide.md:1070` "Last updated (2024)".
5. Trim AI-filler in framework internals: `resources.md` (~50%), `runtime.md` (drop generic Lambda-tuning half), `pulumi.md` (drop "Why Pulumi" + Conclusion) — keep the internals tour at one altitude. Cut `lambda-deployment.md` §9 "Key Lessons" retrospective.
6. Site housekeeping: `packages/doc/README.md` (docs.reventless.dev, five sections), fill or delete the empty `packages/doc/CONTRIBUTING.md`, add the 5-file blog un-draft checklist comment.

**Done when:** the greps in §4 of the analysis come back clean (or intentional); build green.

## Phase 5 — New content

Highest-value gaps (§7), roughly priority-ordered; each is its own commit + sidebar entry.

1. **Authorization guide** (docs-app): AllowAuthenticated default, per-command auth, `commandAuthorization`, Cognito groups, `@index({group, authTable})`, LoginPage/users.yaml/defaultUser/X-User dev flow. (Framework-side architecture twin optional, can be a follow-up.)
2. **Local development guide** (docs-app or tutorials): running reventless-local, ports (4000/4001/3001/3002), `REVENTLESS_LOCAL_BACKEND` memory vs SQLite, seeding users, GraphiQL. Pulls the Split-API-Mode material out of the platform-and-plugin-guide (also shortens the guide toward ~6k words).
3. **Glossary repair**: fix `handle`/`apply` → `decide`/`evolve`, spec-file naming; add DCB vocabulary (tag, partition tag, fence, decision model, consumedEvent), projection, optimistic concurrency, GWT, sury/PPX, Local provider/platform; link it from pages where jargon first appears. Add the tutorial-spine prerequisites box (event-sourcing vocab + `/app/rescript-syntax` link).
4. **Ops chapters** (docs-infrastructure): teardown (`pulumi destroy` ordering, non-empty buckets), cost expectations (from lambda-deployment §4 material), monitoring/DLQ inspection + redrive, deploying-principal IAM + least-privilege overview (incl. the `events:*` caveat).
5. **Symmetry stubs**: local StateTopic note, AWS SideEffectHandler page, EventLogSubscription page; **Postgres backend status stub** (new DCB EventLog Postgres runtime + change-feed relay currently invisible).
6. Backlog candidates (move to `Backlog/` if not tackled here): schema-evolution/event-versioning guide, MCP API surface page, pagination/cursor semantics, reventless-ppx internals page, reventless-local internals page, local architecture page.

**Done when:** items 1–5 published and linked from the relevant sidebars/pages; item 6 triaged into `docs/plans/Backlog/`.

---

## Out of scope

- Blog un-drafting itself (separate decision; Phase 1 fixes its factual error, Phase 4 adds the checklist).
- Docs for commercial/business-repo features — explicitly excluded; Phase 1 removes the existing leakage.
- Restructuring the four-section split — the analysis found it sound; only renames/redirects (Phase 3e).
