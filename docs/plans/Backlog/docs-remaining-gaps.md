# Backlog: remaining documentation gaps

Split out of the audience-path restructure. Each item is independently landable;
none blocks a reader on one of the four paths.

**Rule for all of these:** verify against `reventless/*/src` or the shipped
`examples/`, never against another doc page. Redirects for anything moved. The
build fails on a broken link or anchor, and a D2 diagram that does not compile
leaves no image and no error — check `static/d2/<page>/` after touching one.

## Page rewrites

- **`docs-framework/application-development-layers.md`** — written against the
  pre-PPX API. Either update it to `Product_Behavior.res` / `@@reventless.spec`
  conventions and reframe as "how the framework enforces layer boundaries", or
  fold it into the app-side guide.
- **`docs-framework/ppx-binary-management.md`** — rewrite around the current
  model (gitignored binaries, CI and deploys building from source, the published
  per-platform binary as external-consumer distribution, the local fallback) at
  roughly a third of its length, or fold into maintainer material.
- **`docs-framework/runtime-components/commandgenerator.md`** — the
  `init`/`apply`/`execute` halves and the hand-written `mutationsSchema` predate
  the generated API.

## Deduplication and layering

- **Guide ⇄ tutorial drift.** `platform-and-plugin-guide.md` and the tutorial
  walkthroughs still disagree on several points (behavior state shape, read
  model field names, extension-point style, heartbeat interval, command names).
  The shipped `examples/` are the source of truth. Tutorials should keep the
  narrative and short excerpts and deep-link into guide anchors.
- **`aggregate-based.md` / `dcb-based.md`** repeat near-identical extension
  point, extension, and entry-point sections. `hybrid-based.md` links instead of
  repeating; do the same for the other two.
- **Annotation syntax.** `querydb-key-design-guide.md` and
  `graphql-api-guide.md` §6.4 carry their own `@index` / `@compositeId` /
  `@resolves` references. One owner (`reventless-ppx.md`), verified against the
  PPX source; the others shrink to a sentence and a link. The catalog is also
  missing the `@noTag`/`@noDcbTag` alias note and `@@reventless.visibility`.
- **AWS adapter pages.** `querydb`, `commandtopic`, `task`, `eventcollector`,
  `queryengine`, `commandgenerator`, `heartbeat`, `counter` predate the
  `dcbeventlog.md` template (concept delegated to the component page; physical
  layout, IAM, and config kept). Retrofitting cuts them by roughly half.
  `eventcollector.md` also has a duplicated benefits list and a stray `#`.
  Add the missing adapter → component back-links.
- **`appsync-events-live-updates.md`** is three pages in one: split the user-
  facing half (Stream folders, reconnect refetch, debugging checklist) from the
  wire protocol (→ framework internals) and the zero-downtime handover and
  expand/contract material (→ `deployment-guide.md`).
- **Dedupe to owners:** Lambda layer content → `aws-lambda-layer.md`;
  custom-domain content → `custom-domain.md`; workspace-link mechanics →
  `cross-repo-dev-linking.md`; mixed-source read model →
  `mixed-source-readmodel.md`.
- **`cross-repo-dev-linking.md` + `ppx-binary-management.md`** into a labelled
  Maintainers grouping, with planning language stripped.

## Trimming

- `internals/resources.md`, `internals/runtime.md`, and `internals/pulumi.md`
  carry generic filler ("Why Pulumi", a generic Lambda-tuning half, a
  Conclusion). Keep the internals tour at one altitude.

## New content

- **Symmetry stubs:** local StateTopic, AWS SideEffectHandler,
  EventLogSubscription. Each exists on one side and is undocumented on the other.
- **Schema evolution / event versioning guide.** The single most-asked question
  an event-sourced system raises and the site does not answer it.
- **MCP API surface page** — what the server exposes, now that its status is
  stated accurately in the internals page.
- **Pagination and cursor semantics** for the generated query API.
- **`reventless-ppx` and `reventless-local` internals pages** for contributors.

## Blog

Three posts are `draft: true`, so `/blog` is not generated and its navbar entry
is commented out. Un-drafting is a decision, not a chore — but it needs all of:
the three posts' front matter, the navbar entry in `docusaurus.config.js`, and
`indexBlog: true` in the search plugin config. Doing a subset produces a blog
that exists but cannot be found, or a navbar link that 404s.
