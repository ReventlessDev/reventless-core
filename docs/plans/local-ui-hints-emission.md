# Plan: the in-memory platform serves the ui-hints file a deployment declares

**Status.** Open.

**Sibling work:** `docs/plans/done/ui-manifest-baked-emission.md` — the same seam,
one file over. That plan taught the local platform to write the baked manifest
and the `config.json` overlay into the host shell's served `dist/`. This one
finishes the set: `ui-hints.json` is the third asset the shell fetches from that
directory and the only one a deployment still cannot supply locally.

**Goal.** `hostUiBundleConfig.uiHintsFile` means the same thing on both
platforms: the shell serves the hints file the deployment named, and no other.

---

## §1 — What is actually wrong

`uiHintsFile` is declared on the shared `hostUiBundleConfig` and honoured only by
the AWS deploy, which reads the named file and writes it as a `BucketObject`
beside `config.json` (`reventless/aws/src/Platform.res`). The in-memory platform
ignores it, and says why in a comment at the type
(`reventless/local/src/Platform.res:1431-1434`):

> the host shell is served by `vite dev` against the running in-process GraphQL
> server, not from a CDN, including `uiHintsFile` (the AWS deploy writes it as a
> BucketObject; local dev serves `public/ui-hints.json` directly)

That was true of a dev running the shell from source. It is no longer how the
local platform serves the shell: `HostShellDist` resolves the **installed
package's** `dist/`, and the `ui-hints.json` in there is the host-shell package's
own dev fallback — a file the shell repo authors for its own demonstrations.
The AWS deploy names it as such and excludes it from the upload
(`~excludeFiles=["config.json", "ui-hints.json"]`).

So the two platforms disagree about the same declaration in the worst available
direction:

| | local | AWS |
| --- | --- | --- |
| declared `uiHintsFile` | ignored | served |
| host-shell's own fallback | **served** | excluded |

A deployment that declares hints sees none of them locally, and a deployment
that declares none inherits whatever the shell package happens to ship. Both
halves are silent: hints are presentation, so the failure is a menu that reads
slightly wrong, which nobody debugs.

## §2 — Why the fallback being served locally is right, and why it still needs a baseline

Locally, a dev-mode fallback is in the mode it is for. Deleting it would break
the shell repo's own workflow to fix a problem the shell repo does not have. So
an *undeclared* platform must go on serving it, byte-identical to today.

That makes this the same shape `ShellConfig` already solved, and it needs the
same baseline for the same reason: without one, a withdrawn declaration leaves
yesterday's hints in place with nothing in any diff to explain them. First write
puts the shipped file aside as `ui-hints.base.json`; every write since is
declared-or-baseline. Both directions self-heal, and a `pnpm install` that
replaces the package directory costs one restart.

**Unlike `ShellConfig`, there is no merge.** AWS writes the declared file
verbatim, so local replaces the served file outright. Layering a deployment's
hints over the shell package's demonstration hints would invent a third
behaviour neither platform has, and the winner of any given key would depend on
which repo happened to name it.

## §3 — Shape

```rescript
// reventless/local/src/UiHints.res
let emit: (~uiHintsFile: option<string>, ~dir: option<string>=?) => unit
```

Called from `makePlatform` beside `ShellConfig.emit`, and unconditionally for
the same reason that one is: restoring the shipped file is what a platform that
has stopped declaring anything needs to happen.

Failure modes are the deployment's own mistake and are loud, matching
`BakedManifest.emit`: a declared file that does not exist, a declared file that
is not JSON, and a declaration with no host-shell package installed. Each
produces the same symptom if swallowed — hints that quietly are not applied.

The content is parsed to prove it is JSON and written verbatim. Validating the
hint *vocabulary* is the shell's job and it already does it loudly at
`generateFragments` time, naming the view and the plugin; a second validator in
core would be a copy of the shell's schema that ages separately.

## §4 — Steps

1. `UiHints.emit` + the baseline dance, with a test covering: declared file
   written, withdrawn declaration restored, second boot still starting from the
   shipped file, missing file / bad JSON / absent package all throwing.
2. Call it from `makePlatform`; correct the type comment that says the key is
   ignored.
3. Demonstrate on the hybrid example: `examples/online-shop-hybrid/seed-data/ui-hints.json`
   declared by both platform roots, carrying the storefront's nav and the
   card-to-checkout row action.

## §5 — Acceptance

- A platform declaring no `uiHintsFile` serves exactly the file the host-shell
  package shipped — before and after a boot that once declared one.
- A platform declaring one serves that file's bytes, and the shell applies the
  hints in it.
- A declaration naming a file that does not exist fails the boot, naming the
  path.
