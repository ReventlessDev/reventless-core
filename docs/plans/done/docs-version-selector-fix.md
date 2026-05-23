# Docs Version Selector — make it published-version-aware

**Scope:** Fix the documentation version selector (and version banner) so it
reflects which versions are actually deployed, pre-selects the version you're
viewing, sends unpublished versions to a friendly "not yet released" page instead
of a 404, and updates automatically as `beta`/`main` get published — with no code
change required when a new version goes live.

**Status:** Done (2026-05-23).

**Open decisions resolved:** (1) `versions.html` retired in favour of the in-site
switcher; (2) unpublished versions handled via per-sub-path placeholder pages
(covers direct links); (3) apex redirects to the default published version when
stable is unpublished; (4) version model kept as "Latest = main at root", beta/
alpha under sub-paths.

**Implementation summary:**
- `packages/doc/docusaurus.config.js` — reads the per-build `version-config.js`
  and exposes `customFields.docsVersion`. When that file is absent (local dev),
  it derives the version from the current git branch (`main → latest`, `beta`,
  `alpha`; anything else → `"local"`) so the switcher/banner reflect the branch
  you're previewing instead of always defaulting to `latest`.
- `packages/doc/src/components/VersionSwitcher.js` — fetches `versions.json` at
  runtime, pre-selects the current version, shows unpublished entries as
  "(coming soon)", routes unpublished selections to their placeholder, and
  degrades to a single entry when the manifest is absent.
- `packages/doc/src/components/VersionBanner.js` — driven by the current version;
  the "View Latest Stable Docs" link only renders when the manifest reports
  `latest` published.
- `.github/workflows/deploy-docs.yml` — the old "Create version selector landing
  page" step is replaced by "Generate version manifest, placeholders, and apex":
  computes the published set from real (non-placeholder, sentinel-tagged) docs in
  `build-output`, writes `versions.json` + `default`, generates "not yet released"
  placeholders for unpublished sub-paths, redirects the apex to `default` when
  stable is unpublished, and removes any preserved `versions.html`.
- `packages/doc/.gitignore` — ignores the generated `version-config.js`.

**Verified:** docs build compiles (`docsVersion:"local"` injected with no
`version-config.js`); the manifest/placeholder/apex bash logic was simulated
across alpha-only, alpha+beta, all-three, and empty scenarios (incl. the
sentinel re-mirror case) with valid JSON and correct defaults; workflow YAML
parses and the step is correctly ordered.

**Related:** This realizes part of the open-source publication plan's Phase 8
"Versions UI" open decision (#4) — choosing the in-site `VersionSwitcher` path and
making it correct, rather than the static `versions.html` selector.

---

## The problem (root cause)

Three things are hardcoded and disconnected from reality:

1. **`VersionSwitcher.js`** lists `Latest (/)`, `Beta (/beta/)`, `Alpha (/alpha/)`
   unconditionally and navigates to those paths whether or not they're deployed.
   Selecting an undeployed version → **Page Not Found**.
2. **Current-version detection** (`VersionSwitcher.js`, `VersionBanner.js`) keys off
   `siteConfig.baseUrl` substrings (`/beta/`, `/alpha/`). On the deployed alpha
   site `baseUrl` is `/reventless-core/alpha/` so it works there, but locally and
   at the apex it's `/reventless-core/` → mis-detected as "Latest".
3. **The deploy model** (`.github/workflows/deploy-docs.yml`) puts **main at the
   root** (`build-output/`) and `beta`/`alpha` under sub-paths. With only `alpha`
   docs published, the **root is empty** and `Latest`/`Beta` point at nothing.

Net effect today: with only alpha live, the apex/root and the Latest/Beta links
404, and the selector neither pre-selects alpha nor knows it's the only published
version.

---

## Goals

- The selector and banner are driven by a **single source of truth** listing which
  versions are actually published.
- The version you're viewing is **pre-selected**.
- Selecting (or directly visiting) an **unpublished** version shows a friendly
  **"not yet released"** page — never a 404.
- When `beta` or `main` get published, the selector **updates automatically** with
  no code change (driven by the deploy workflow regenerating the manifest).
- The **apex/root** always resolves to something useful (the best available
  version), never an empty 404.
- **Local dev** (single build, no sub-paths) degrades gracefully — no broken links.

---

## Design

### 1. Source of truth: a runtime `versions.json` at the site root

The deploy workflow already knows which branches exist and (via the `wget` mirror
step) which versions are already live on Pages. Have it emit a single
`build-output/versions.json` at the site root describing every version and whether
it is **published**:

```json
{
  "default": "alpha",
  "versions": [
    { "id": "latest", "label": "Latest", "badge": "STABLE",       "path": "/reventless-core/",       "published": false },
    { "id": "beta",   "label": "Beta",   "badge": "PRE-RELEASE",  "path": "/reventless-core/beta/",  "published": false },
    { "id": "alpha",  "label": "Alpha",  "badge": "EXPERIMENTAL", "path": "/reventless-core/alpha/", "published": true  }
  ]
}
```

- `published` = the version's docs are actually present after build + preserve
  (branch built this run **or** already existed in the downloaded `build-output`).
- `default` = the version the apex should route to: highest published in
  `latest → beta → alpha` precedence.
- One manifest at the **site root**, shared by every version sub-site.

**Why runtime fetch (not build-time injection):** each version is a separate
Docusaurus build. If the switcher only knew the published set at *its* build time,
publishing `beta` later wouldn't update the already-built `alpha` switcher. Fetching
`/reventless-core/versions.json` at runtime (same origin for all versions) means a
new deploy's regenerated manifest is picked up everywhere automatically —
satisfying the "auto-update when published" requirement.

### 2. No 404s: generated placeholders for unpublished sub-paths

In the workflow, after building, ensure **every** version sub-path has an
`index.html`:

- Published version → its real docs (as today).
- Unpublished version → a generated **"not yet released" placeholder** page
  (`build-output/beta/index.html`, etc.) styled to match, explaining the version
  isn't released yet and linking to the `default` published version.

This guarantees direct/bookmarked links to `/beta/` never 404, and the placeholder
is replaced by real docs automatically when that version publishes.

### 3. Apex/root behavior

Generate the root `index.html` from the manifest:

- If `main` (latest) is published → root is the main docs (current behavior).
- Else → root is a tiny **redirect** to `default` (e.g. `/reventless-core/alpha/`),
  so the apex is never empty. (Keep `versions.html` as an explicit chooser, or
  regenerate it from the manifest — see Open decisions.)

### 4. Robust current-version detection

Inject the building version into the site so components don't have to guess from
`baseUrl`:

- The workflow already writes a `version-config.js` per build; wire the version id
  into `docusaurus.config.js` `customFields` (e.g. `customFields.docsVersion`).
- Components read `siteConfig.customFields.docsVersion` for pre-selection, falling
  back to the `baseUrl` heuristic, then to `default` from the manifest.

### 5. Rewrite `VersionSwitcher` and `VersionBanner`

- **VersionSwitcher**: fetch `versions.json` on mount; render the dropdown from it;
  mark the current version selected; show unpublished versions as
  `"Beta (coming soon)"`; on selecting an unpublished version, navigate to its
  placeholder (or an in-site `/unreleased` page) rather than a dead docs path.
  While the manifest is loading or absent (local dev), render just the current
  version (no network-dependent breakage).
- **VersionBanner**: drive the banner from the current version + manifest; fix the
  hardcoded `/reventless-core/` "View Latest Stable Docs" link to point at
  `default` (or hide it when no stable exists).

### 6. Local-dev fallback

With no `versions.json` and a single build at `/reventless-core/`, the switcher
shows a single "Local"/current entry and the banner is suppressed — no fetch error,
no broken links.

---

## Implementation steps

1. **Workflow — manifest.** In `deploy-docs.yml`, after the build/preserve steps,
   compute the published set (branch built this run OR `build-output/<path>/index.html`
   already exists from the wget mirror) and write `build-output/versions.json` +
   set `default`.
2. **Workflow — placeholders.** For each unpublished version, write a styled
   `build-output/<path>/index.html` "not yet released" placeholder (template lives
   in the workflow or a checked-in HTML fragment).
3. **Workflow — root.** When `latest` is unpublished, write a root `index.html`
   redirect to `default`; otherwise leave the main build at root. Regenerate
   `versions.html` from the manifest (or retire it — Open decisions).
4. **Config — current version.** Read `version-config.js` (or an env var) in
   `docusaurus.config.js` and expose `customFields.docsVersion`.
5. **Component — VersionSwitcher.** Rewrite to fetch the manifest, pre-select the
   current version, render published vs "coming soon", route unpublished selections
   to the placeholder/`unreleased` page, and fall back gracefully in dev.
6. **Component — VersionBanner.** Drive from current version + manifest; fix the
   stable-docs link.
7. **(Optional) In-site `unreleased` page** (`src/pages/unreleased.js`) reading
   `?v=` for a nicer in-app message, if placeholders alone aren't enough.
8. **Verify**: build locally (graceful single-version fallback); simulate a
   multi-version `build-output` (alpha only; alpha+beta; all three) and confirm the
   switcher pre-selects correctly, unpublished routes to the placeholder, the apex
   redirects, and publishing a new version flips it to a working link with no code
   change.

---

## Acceptance criteria

- With only `alpha` published: alpha is **pre-selected**; selecting **Beta** or
  **Latest** shows the "not yet released" page (no 404); the apex redirects to
  alpha.
- Publishing `beta` (deploy) makes **Beta** a working link automatically — no code
  or component change.
- On each deployed version sub-site, the **correct version is pre-selected**.
- Local `pnpm run build` + serve: switcher and banner render with no fetch errors
  and no broken links.

---

## Open decisions

1. **Keep `versions.html`?** Retire it in favour of the in-site switcher
   **(recommended)**, or regenerate it from the manifest as a fallback chooser.
2. **Unpublished UX:** static per-sub-path **placeholder pages (recommended,
   also covers direct links)** vs. an in-site `/unreleased` route reached only via
   the switcher.
3. **Apex when stable is unpublished:** **redirect to `default` (recommended)** vs.
   serve the version chooser at the apex.
4. **`latest` ↔ `main` naming:** keep "Latest = main at root" (current model, aligns
   with the deferred Phase 8 reventless.dev cutover) — confirm before implementing.
