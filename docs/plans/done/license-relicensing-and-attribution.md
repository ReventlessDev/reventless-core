# License Relicensing & Attribution Plan (MIT → Apache 2.0)

**Scope:** Apply the agreed copyright/licensing decisions to this repository before
the open-source release: relicense MIT → **Apache 2.0**, correct the copyright
holder, add the Apache **NOTICE**, consolidate author identities (`.mailmap` +
`AUTHORS`), add a DCO sign-off for future contributors, and scrub the remaining
employer hostnames from test code. Touches only governance/metadata files and one
test fixture — **no framework behavior changes**. This plan covers **this repository
(reventless-core, the framework) only**; the UI is a separate repository handled
independently (see § Out of scope).

**Status:** Completed — 2026-05-25. T1–T6, T8 applied; T7 (per-file headers) deferred
as planned. One deviation: `.kilocode/package.json` (config for the third-party Kilo
Code tool — no name/version, not our code) was **left unlicensed** rather than set to
Apache-2.0, per the T3 "do not license third-party" caveat; all 47 first-party
manifests are `Apache-2.0`.

**Provenance of these decisions:** the chain-of-title legal analysis that justifies
the holder, the year span, and the attribution approach lives in a **separate,
private repository** and is intentionally **not linked here**. This plan records
only the operational decisions and the steps to apply them in this repo. (Same
rule the docs-site plan follows for the private UI repo: names of facts are fine;
links to private repos are not.)

**Related work in this repo:**
- [`docs-site-open-source-publication.md`](./docs-site-open-source-publication.md) —
  the Docusaurus footer (`Copyright © <years> Reventless`) is already correct and
  is handled there. **Not** in scope here (see § "Out of scope").

---

## Canonical values (use these everywhere)

| Item | Value | Note |
|---|---|---|
| License | `Apache-2.0` (SPDX) | Patent grant + NOTICE mechanism + enterprise acceptance. |
| Copyright holder | `Martin Lorenz` | A legal person — **not** the `ReventlessDev` GitHub handle (the current LICENSE wrongly uses `ReventlessDev`). |
| Software copyright year | `2019–2026` | Development span → release year. |
| Attribution suffix | `and contributors` | Covers future OSS contributors. |
| Named original authors | **Christoph Wanasek**, **Mario Krizic**, **Christoph Pader** | The three contributors whose work clearly clears the authorship threshold (Pader: the 2020 Plugin system + VPC support, identified from the Git history). Other historical contributors are credited via the retained Git history + `AUTHORS`, not named in NOTICE. |
| Docs-website year | `2026` (auto-ranges) | A separate 2026 work — already correct, not changed here. |

---

## Current state (grounded, 2026-05-24)

| Thing | State |
|---|---|
| Root [`LICENSE`](../../LICENSE) | **MIT**, `Copyright (c) 2019-2026 ReventlessDev` (wrong holder). |
| `package.json` license fields | 48 manifests (excl. `node_modules`): **42 = `"MIT"`**, **1 = `"SEE LICENSE IN LICENSE.md"`** ([`reventless/reventless-conventional-changelog/package.json`](../../reventless/reventless-conventional-changelog/package.json)), **5 = no `license` field**. |
| [`README.md`](../../README.md) | § "📄 License" (line ~141) just says `MIT`; **no Provenance section**. |
| [`CONTRIBUTING.md`](../../CONTRIBUTING.md) | **Exists** (full guide). **No DCO / sign-off** anywhere. |
| `NOTICE`, `AUTHORS`, `.mailmap` | **All absent.** |
| Docusaurus footer | `COPYRIGHT_START_YEAR = 2026`, footer `Copyright © <years> Reventless` — **already correct**. |
| Employer hostnames in code | Only [`reventless/reventless-core/tests/ftp/FTPTest.res`](../../reventless/reventless-core/tests/ftp/FTPTest.res) (20 occurrences of `*.atos.net`) + its generated `.res.mjs`. `FIDAP` / `Strohgasse` / `eviden.com` / customer-name strings: **0 in the live tree.** |

---

## Tasks

### T1 — Relicense `LICENSE` to Apache 2.0
Replace the MIT text in [`LICENSE`](../../LICENSE) with the **verbatim** official
Apache License 2.0 (<https://www.apache.org/licenses/LICENSE-2.0.txt>). In the
"APPENDIX: How to apply" boilerplate at the bottom, set the copyright line to:

```
Copyright 2019-2026 Martin Lorenz
```

This also fixes the wrong holder (`ReventlessDev` → `Martin Lorenz`).
**Acceptance:** `LICENSE` is byte-for-byte the Apache 2.0 text + the line above; no MIT text remains.

### T2 — Add `NOTICE`
Create a new root `NOTICE` (Apache requires downstream redistributions to preserve
it, so keep it minimal — required attribution only):

```
Reventless
Copyright 2019-2026 Martin Lorenz and contributors

Portions of this software were originally developed (2019-2025) by employees of
Atos Austria GmbH / Eviden Austria GmbH, principally Christoph Wanasek,
Mario Krizic and Christoph Pader. See the Git history for the full list of
contributors.

Licensed under the Apache License, Version 2.0. See the LICENSE file.
```

**Acceptance:** `NOTICE` exists with the above; named authors are Wanasek, Krizic, Pader (D1 resolved — see T5).

### T3 — Set `Apache-2.0` in every `package.json`
- The **42** `"license": "MIT"` → `"license": "Apache-2.0"`.
- The **5** with no `license` field → add `"license": "Apache-2.0"`.
- The **1** `"SEE LICENSE IN LICENSE.md"`
  ([reventless-conventional-changelog](../../reventless/reventless-conventional-changelog/package.json)) —
  **verify first** whether this package is a vendored third-party fork. If it is
  our code → `"Apache-2.0"`; if it carries an upstream license → leave it and note
  why in NOTICE. (It currently points at a `LICENSE.md` that does not exist at the
  package root — resolve this.)
- **Caveat:** do not relicense any genuinely vendored third-party source. Confirm
  none of the 48 packages re-publish someone else's code under our manifest.

**Acceptance:** every first-party `package.json` reads `"license": "Apache-2.0"`; any exception is documented in NOTICE.

### T4 — README: License + Provenance
In [`README.md`](../../README.md) replace the bare `MIT` under "📄 License" with:

```markdown
## License

Reventless is licensed under the [Apache License 2.0](LICENSE).
```

Add a short **Provenance** section. **D2 — RESOLVED (2026-05-24): short form.**
Name the original developer (Atos/Eviden) but **not** the intermediate customer
entity — the customer name stays on the code-scrub list and is deliberately kept
out of the public repo. Use:

```markdown
## Provenance

Reventless was originally developed (2019–2025) by Atos Austria GmbH /
Eviden Austria GmbH and used in production before its open-source release.
The intellectual-property rights were subsequently transferred to Martin
Lorenz, who released it under the Apache License 2.0 in 2026.
See [NOTICE](NOTICE) for original-author attribution.
```

**Acceptance:** README states Apache 2.0 and links `LICENSE`; a short-form Provenance section exists (**no customer name**); the README license badge (if any) is updated.

### T5 — `.mailmap` + `AUTHORS` (identity consolidation)
Author attribution (the non-transferable moral right) is satisfied by retaining the
Git history. Consolidate the scattered identities so each human appears once.

Identities seen in `git log --all` (commit counts):

| Human | Identities to map | Commits |
|---|---|---|
| Martin Lorenz | `martin.lorenz@atos.net`, `malo@reventless.dev`, `martin.lorenz66@gmail.com`, `malo@users.noreply.github.com` | ~3572 |
| Christoph Wanasek | `Christoph Wanasek`/`Christoph Porod-Wanasek`/`Christoph` @ `christoph.wanasek@atos.net` + `christoph.wanasek@hotmail.com` | ~621 |
| Christoph Pader | `Christoph Pader`/`Christoph` @ `christoph.pader@atos.net` + `chrispad2k@gmail.com` | 52 |
| Mario Krizic | `Mario Krizic`/`mrkrizic` @ `mario.krizic@eviden.com` | ~117 |
| Bots (exclude from AUTHORS) | `github-actions[bot]`, `dependabot[bot]`, `Claude <noreply@anthropic.com>` | — |

> **D1 — RESOLVED (2026-05-24): Christoph Pader is a distinct fifth original
> author.** Verified from `git log --all`: **52 commits, 2020-06-16 → 2021-03-22,
> +723 / -124 lines of `.re`/`.res` source** — the early Plugin system
> (`PluginAggregate` / `PluginView` / `PluginSpec` / `PluginBehaviour` + tests) and
> VPC support (`Util_Vpc`, Lambda `vpcConfig`). He is a **different person** from
> Christoph Wanasek (different surname; emails `christoph.pader@atos.net` /
> `chrispad2k@gmail.com` vs. `christoph.wanasek@*`). His work clears the authorship
> threshold, so he is **named in NOTICE** (T2) and listed in `AUTHORS`. He was
> absent from the original four-author legal list, which has been corrected.

Then write `AUTHORS` listing each consolidated human (bots excluded).
**Acceptance:** `git shortlog -sne` collapses to one line per human; `.mailmap` + `AUTHORS` committed; D1 resolved (Pader = distinct fifth author).

### T6 — Add DCO sign-off to `CONTRIBUTING.md`
The file already exists; **add** a "Developer Certificate of Origin" section
requiring `git commit -s` (`Signed-off-by:`) on contributions. This prevents the
ownership question from recurring with external contributions (lighter than a CLA,
fits Apache 2.0). Place it near "Submitting Changes" / "Commit Guidelines".
Optionally wire a DCO check (bot/CI) — separate follow-up, not blocking.
**Acceptance:** CONTRIBUTING.md documents the DCO and the `-s` requirement.

### T7 — Source-file headers (optional, deferred)
Apache does **not** require per-file headers; retro-fitting hundreds of `.res`
files is optional. If desired, apply the lightweight SPDX short form to key
entry-point files only:

```
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2019-2026 Martin Lorenz
```

**Recommended:** skip for the initial release (LICENSE + NOTICE + package manifests
are sufficient). Track as a nice-to-have.

### T8 — Scrub employer hostnames from test code
[`reventless/reventless-core/tests/ftp/FTPTest.res`](../../reventless/reventless-core/tests/ftp/FTPTest.res)
has 20 `*.atos.net` test hostnames → replace with `example.com`.
- **Edit only the `.res` source, then `bun run build`** to regenerate
  `FTPTest.res.mjs`. Never hand-edit the `.res.mjs` (compiler output).
- Re-run the affected test(s) after rebuild.

**Acceptance:** `grep -rI 'atos.net' reventless/ --include='*.res'` returns nothing; FTP tests pass after rebuild.

---

## Sequencing

1. **T5 / D1** — ✅ resolved: Pader is a distinct fifth author (named in NOTICE,
   listed in AUTHORS). The `.mailmap` consolidation itself still precedes T2/T4 so
   the NOTICE/AUTHORS names line up with `git shortlog`.
2. **T1, T3, T8** — mechanical, independent; can land together.
3. **T2, T4** — ready (D1/D2 both resolved); land after the `.mailmap`
   consolidation so the NOTICE/AUTHORS names line up with `git shortlog`.
4. **T6** — independent; any time.
5. **T7** — deferred.

Land as one focused "chore(license): relicense to Apache 2.0 + attribution" change
(or a small series). Commit messages describe framework/repo changes only.

---

## Out of scope

- **Docusaurus footer / docs-site copyright** — already correct; owned by
  [`docs-site-open-source-publication.md`](./docs-site-open-source-publication.md).
- **reventless-ui** — the UI is a **separate repository** (it shares early
  mono-repo history with this repo but was split out; no UI code is present here).
  It is **not** part of this release. Its own Apache 2.0 relicensing + attribution
  would be a separate future effort, planned if/when the UI is open-sourced.
- **Non-code legal prerequisites** (rights-holder confirmations, repository-scope
  snapshots, patent confirmation, contract checks). These are maintainer actions
  tracked privately, not repository edits — not represented here.
- **DCO enforcement bot/CI** — optional follow-up to T6.
- **Relicensing vendored third-party code** — explicitly excluded (T3 caveat).
