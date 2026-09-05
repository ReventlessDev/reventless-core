# Plan: a deployment can name the module that draws its own surfaces

**Date:** 2026-09-05

**Status.** §2, §3 and §4 are done — the declaration exists on both platforms,
the local platform serves and watches the declared module, and the AWS deploy
writes it beside `config.json`. §6 has the deployment half (`uiSlotsFile` in
`ui-configuration.md` §4.1, and the local watch loop in the local-dev guide); the
hint-side vocabulary it also names (`audiences`, `slots` per view) belongs to the
host shell package and is written when that ships.

**The seam is connected.** The declaration writes two things, and needs both: the
module as an object, and the `uiSlotsUrl` key naming it. `SlotModules.load`
imports what that key names and imports nothing when it is absent, so the object
alone was a file nothing fetched — with no symptom, because a shell that fetches
no slots draws its own regions exactly as an undeclared deployment does. The key
is computed on both platforms and refuses a `shellConfig` redirect, like
`manifestUrl`; the string it shares with the written object lives in
`ReventlessCore.Platform_UiSlots` so the four places that must agree cannot
drift.

**Still blocked: §5, the example — now on a release rather than on the work.**
The UI half has landed (`reventless-ui` `49feb25`, plus the public
`@reventlessdev/reventless-ui-slots` package) but is **unpublished**: the latest
`reventless-host-shell` is `3.0.0-alpha.94`, which the example pins and which
contains no slot loader. §5 needs that release and the pin bumped to it.
Declaring a `uiSlotsFile` against `alpha.94` writes and serves the file
correctly, and nothing imports it.

This is the deliberate shape of the seam, not an accident of ordering: the file
is served whether or not anything imports it, so the deployment half can land,
be tested and be documented before the consumer exists.

**Sibling work:** [`local-ui-hints-emission.md`](./local-ui-hints-emission.md) —
the same seam, one file over. That plan taught the in-memory platform to serve
the `ui-hints.json` a deployment declares (`b29b1044f`, `8258c8581`), including
the baseline handling and the watch that reloads it on save. This plan adds the
second file of the pair and copies its shape deliberately.

**Goal.** `uiSlotsFile` means on both platforms what `uiHintsFile` already
means: the shell serves the module the deployment named, editing it is a browser
refresh locally, and a deployment that names none behaves exactly as it does
today.

**One correction to §2–§4 as written below:** they describe the file and say
nothing about naming it, which is a whole half of the seam. `uiHintsFile` is
served at a fixed URL the shell already knows; a slot module is imported from
whatever `config.uiSlotsUrl` names, so declaring the file has to write that key
too. Read every "write the file" below as "write the file and name it".

---

## §1 — What is missing

A deployment can already say a great deal about its generated surface without
building anything: which mode a view opens in, what the nav calls it, which
semantics a field carries, which commands a row offers. All of it travels in one
declared file.

What it cannot say is how a region should be *drawn*. A hint carries the
decisions that can be stated — which mode, which field, which command, where a
click goes. It cannot carry a tile with the name set over the picture, a card
face in a different type scale, a step label under a tracker node. Today the only
way to change a tile is to write a whole view mode, which means taking ownership
of paging, the window sentence, the action offers, the drill target and the
live-update path — every one of which the mode you were otherwise happy with
already had right.

The UI repo's companion plan closes that with a slot registry: a mode declares
named regions, a small registered renderer fills one, and the mode keeps
everything else. A registry needs populating, and the population has to reach
every caller — including the ones served from a baked manifest, who never issue
an admin query and for whom federation overrides therefore do not apply. That
rules out the out-of-tree fragment path and leaves exactly one seam: **a module
in the browser bundle, fetched at boot from a URL the deployment names.**

Naming that URL is this repo's half, and it is the same declaration-and-emission
work `uiHintsFile` already went through twice.

---

## §2 — The declaration

One field beside `uiHintsFile` on the shared `hostUiBundleConfig`
(`reventless/infra/src/types/Platform.res`), with the AWS record mirroring it:

```rescript
// Optional path to an ES module registering AutoUI slot renderers, read and
// written verbatim beside `config.json` at deploy time. Unset ⇒ no file
// written; the shell treats the 404 as "no slots" and every mode draws its
// own regions.
uiSlotsFile?: string,
```

Verbatim, like the hints file: this is a deployment's own source, and a build
step over it would make the local watch a lie and put a bundler between an author
and their own file.

While in that record — the `uiHintsFile` comment still says *"In-memory
platforms ignore this"*, which the sibling plan's commits made false. Fix it in
the same change rather than copying a stale sentence into the new field.

---

## §3 — Local: serve it, and reload it on save

`reventless/local/src/UiHints.res` is the template and most of it generalizes:
resolve the declared path, serve it at a fixed URL beside `config.json`, fall
back to nothing when unset, and watch the file so an edit is a browser refresh
rather than a platform restart.

Two things differ from the hints file and both matter.

**There is no baseline to protect.** The hints work had to reckon with the
host-shell package shipping its own `ui-hints.json` as a dev fallback — a file
the shell repo authors for its own demonstrations, which a deployment declaring
no hints would otherwise silently inherit. The shell ships no slots module, so
"unset" means "no file" with no third party's opinion underneath. Keep it that
way: **do not add a fallback slots module to the host shell.** A dev fallback for
rendering would be a fallback for *appearance*, and inheriting a stranger's
appearance is exactly the failure that is hard to notice.

**A broken module fails differently from broken hints.** Malformed hints decode
leniently and the surface survives. A module that throws at import takes its
whole registration with it. The shell side handles that (log, skip, continue —
the registration hook's existing stance), but the local platform should not make
it worse by serving a stale copy after a failed edit: serve what is on disk, let
the shell report what it could not use.

---

## §4 — AWS: one more `BucketObject`

The deploy reads the named file and writes it beside `config.json`, exactly as it
does for hints (`reventless/aws/src/Platform.res`). Same `~excludeFiles`
treatment so a shell-bundled file of the same name could never shadow a
deployment's own.

**Two hazards to build against, both known and both silent.**

*A 404 that is not a 404.* A serving handover can clobber the served bucket's S3
policy, at which point requests that should 403 come back as the SPA's
`index.html` with a **200**. For an image that shows as a broken picture. For an
ES module it shows as a syntax error inside HTML, and the message will point at
`<!doctype`, not at the deployment. Whatever the shell does on a failed slots
load must therefore survive *receiving HTML where it expected a module* — check
the content type, and say the deployment's file name in the log line, because the
parser error will not.

*Origin and CSP.* The module rides the same distribution as the bundle, so it is
same-origin and no CSP relaxation should be needed. Confirm that rather than
assume it — a slots file that silently fails to load on AWS and works locally is
the worst shape this can take, and it is the shape it will take if the CSP
question goes unasked.

**Asked and answered:** this deploy sets no `Content-Security-Policy` at all —
there is no `responseHeadersPolicy` anywhere in `reventless/aws/src`, so nothing
restricts `script-src` and the same-origin module loads with no relaxation to
make. What the deploy does owe is the content type, which is the difference
between the shell importing the file and refusing it, so `ui-slots.js` is written
with an explicit `application/javascript; charset=utf-8` rather than left to a
default. Re-ask the CSP question if a headers policy is ever added.

---

## §5 — The example earns the seam

`examples/online-shop-hybrid` is where this becomes something a reader can open,
change and run, which is the whole reason the seam is public rather than private.

- **`seed-data/storefront-slots.js`** — a plain ES module, no bundler, no
  ReScript, no dependency, exporting one `register`. It should be readable in one
  sitting: a category tile, a product face, a product media panel, a tracker step
  label, and a small stylesheet's worth of tokens.
- **`seed-data/ui-hints.json`** — the audience block that switches them on,
  which is the part to keep small on purpose. The demonstration is that the file
  deciding what a caller sees is a JSON edit that can be made and reverted live.
- **`platform-local`** — `uiSlotsFile` declared beside `uiHintsFile`, so
  `pnpm run dev:full` serves both and watches both. No extra process, and no
  `dev:ui` hook: that path is for contributors working on UI *source*, and
  reaching for it here would quietly move the example off the seam it exists to
  demonstrate.

**Keep the example honest about what it does not have.** Two things it would be
natural to draw are not in the data — a per-category product count, and product
thumbnails on an order card, which live in another plugin's read model. Both are
missing *data*, and the answer is a projection field or a wider mirror decided in
the domain, not a number computed in a renderer. Leave them out. An example that
fakes them teaches the one habit this seam most needs people not to have.

---

## §6 — The guide

`packages/doc/docs-app/ui-configuration.md` gains the new keys beside the
existing hint vocabulary: the `audiences` block and its resolution rule, `slots`
per view, and `uiSlotsFile` as a deployment declaration. Two points to make
explicitly, because both are load-bearing and neither is guessable:

- **A slot renders what it was handed and reads nothing else.** No queries of its
  own, no hard-coded command names. A renderer that reaches past its payload has
  stopped being a rendering of the generated data plane.
- **Slots do not replace pages, routes or modes.** What this seam offers is
  custom drawing inside the regions of standard components. A page of its own is
  a different seam with a different cost, and the guide should say so where
  someone is deciding which they need.

---

## §7 — Verification

- **Local.** Declared file served; edited file live on refresh; undeclared file
  → nothing served and the surface fully generated; a module that throws at
  import → the shell logs once and every mode draws its own regions.
  **Done** — `UiSlotsTest` covers the emission (verbatim write, nothing written
  when undeclared, the file *removed* on withdrawal, a missing declaration
  failing the boot, the last good copy surviving a bad one) and the watch (real
  `fs.watch` events, a re-serve on save, and a save that momentarily removes the
  file reported rather than thrown). The last of these is the shell's half and
  is verified there.
- **AWS.** Declared file present beside `config.json` after a deploy and served
  with a JavaScript content type; undeclared → absent; the HTML-instead-of-404
  case above exercised deliberately, since it will not occur on demand later.
  **Not yet run** — the emission compiles and an undeclared deployment is
  unchanged by construction (the `switch` writes nothing), but no deploy has
  declared a file, so "present, and served as JavaScript" is unobserved. Worth
  doing on the deploy that carries the example, where there is a file to look at.
- **The example, by hand.** One deployment, one login, one data set: switch role
  and watch the same views redraw. Then delete the audience block and save — the
  surface returns to the generated console with no reload and no deploy. That
  last step is the verification that matters; if it does not work live, the seam
  is not finished whatever the unit tests say.

---

## Sequencing and dependencies

1. §2 declaration — self-contained, and it is what the other two halves read.
2. §3 local, then §4 AWS. Local first because the example is developed against it
   and because the watch is where a mistake shows up immediately.
3. §5 example — needs the UI repo's registry released and the example's pin
   bumped to a version containing it. Until that pin lands, a slots file here
   registers into nothing and the example would look broken for a reason that has
   nothing to do with this repo.
4. §6 guide, last, once the key names have stopped moving.
