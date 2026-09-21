# ReScript version upgrade: 12.3.1 now, 13 later

**Date:** 2026-09-21<br/>
**Status:** 12.3.1 adopted on 2026-09-21 (steps 1 and 2 below). v13 is still open. The
[trial build](#trial-build-of-1231) ran in a separate worktree before adoption. The rest is
based on the upstream release notes and changelog, plus a search of this repo's sources,
`rescript.json` files and `package.json` pins.<br/>
**Related:** [rescript-rewatch-utf8-stdout-panic.md](../../fixes/rescript-rewatch-utf8-stdout-panic.md)<br/>
**Open steps (3–5) planned in:** [rescript-13-upgrade.md](../../plans/Backlog/rescript-13-upgrade.md)

---

## In plain words

The repo pins the ReScript compiler to exactly **12.3.0**. There are two newer lines:

- **12.3.1** is a patch release that came out on 2026-08-24 and is npm's `latest`. It fixes
  the build crash that blocks a clean build of the host shell, and it tightens a few
  type-checking rules. We should take it now. The trial build found **one blocker, in our
  PPX**: it emits lambdas without arity information, which 12.3.1 rejects. A three-line PPX
  fix, which also works on 12.3.0, clears it. With that fix, the build, all 4,626 tests and
  every golden check pass unchanged.
- **13.0.0** is still in alpha (`13.0.0-alpha.6`, 2026-09-16). This repo's own code is
  already free of every API that v13 removes. What blocks the upgrade is two outside
  dependencies: **sury** (its peer dependency is `rescript: 12.x`) and the **PPX** file
  format, which v13 promises to keep but has not yet shipped in a stable release. Wait for
  v13 final and a matching sury release.

## Words used here

- **rewatch**: ReScript's build tool, written in Rust. It is what `rescript build` runs in v12.
- **PPX**: a compiler plugin that rewrites source before type checking. This repo uses two:
  `reventless-ppx` (our own, written in OCaml on `ppxlib`) and `sury-ppx`.
- **Frozen PPX format**: the fixed layout in which the compiler hands the syntax tree to an
  outside PPX program (internally "Parsetree0"). While that format stays the same, PPX
  binaries built for one compiler version keep working with the next.
- **Peer pin**: a package's `peerDependencies.rescript`, meaning "the compiler the consumer
  must bring along".

---

## Where the repo is today

| Item | Value |
|---|---|
| Compiler | `rescript` **12.3.0**, pinned exactly. 95 occurrences across 53 `package.json` files, 42 of which also list it as a peer dependency |
| Sibling repos | tools: a mix of `12.3.0` and `^12.3.0`. UI and business: `^12.3.0` |
| READMEs | `Requires ReScript ^12.3.0 (peer dependency)` in core, aws, effect, graphql-yoga, mcp-sdk. **This does not match** the exact `12.3.0` in the manifests |
| Module format | all 55 `rescript.json` files use `"module": "esmodule"` |
| Serialization | `sury` / `sury-ppx` **11.0.0-rc.2** (11.0.0 final is out) |
| Node | 22.17.1 |
| Known 12.3.0 bug | a clean full build of `reventless-host-shell` crashes rewatch (`stdout should be non-null: Utf8Error`); see the related fix note |

---

## 12.3.1: what changes for us

Release notes: [v12.3.1](https://github.com/rescript-lang/rescript/releases/tag/v12.3.1).

### Fixes we want

- **#8482: build crash on compiler output that isn't valid UTF-8.** This is exactly the
  host-shell clean-build crash described in the related fix note. The one-line upstream
  patch that note proposes is no longer needed, and neither is the draft issue in it.
- **#8520:** multibyte characters are preserved when long lines are wrapped in code frames.
  This fixes the same kind of bug in the part of the output that produced the bad bytes.
- **#8408:** rewatch replays warnings after an early compile error. This matters for the
  zero-warnings grep: warnings that are hidden today may now show up.

### Changes that can make code that compiles today fail

- **#8559: function arity is enforced in module inclusion, type equality and coercion.**
  This is the one real risk. The framework is built from functors and first-class modules
  (`module type T`, `*.Make(Spec)`, `include ReventlessGwt.<Kind>_GWT.Make(Spec)`). A
  signature that the compiler used to accept even though the arity differed (for example
  `(a, b) => c` against `a => b => c`) will now be rejected. The PPX-generated code is
  exposed as well as hand-written code, because the PPX emits module bodies that are
  checked against module types.
- **#8563:** a bare labelled arrow type (`~x: int => string`) now gets an arity. Code that
  only compiled because of the missing arity can break. Code that failed for that reason
  now works.

### Changes to the compiled JavaScript

- **#8572: argument evaluation order for inlined calls.** Arguments that have side effects
  used to be evaluated last to first when the optimiser inlined a call. They are now
  evaluated in source order. This is a correctness fix, but it changes the compiled
  `.res.mjs` output, including tracked files under `src/`.
- **#8568:** defaults of optional parameters are computed when their own group of curried
  arguments is applied. Only code that uses optional arguments with defaults across curried
  groups sees the difference.
- **#8550:** parentheses around `*`, `/`, `%` used as an exponent are kept. This changes
  both the formatter output and the compiled output.

### Formatter

- **#8444:** trailing comments before `=` in `let` bindings are formatted differently. The
  tree is kept formatter-canonical and CI checks that, so `pnpm run format:res` may rewrite
  some files. Those rewrites belong in the same commit as the bump.

### Nothing to do

- Editor analysis fixes (#8455, #8566) and termination analysis fixes (#8568).

### Pins

The bump changes all 95 occurrences, including every peer pin. A consumer on `^12.3.0` gets
12.3.1 in any case. A core package that peer-pins exactly `12.3.0` then gives that consumer
a peer mismatch warning. **Recommendation:** at the same time, relax the peer pins to
`^12.3.1`, which is what the READMEs already say. Keep `devDependencies` exact so CI stays
reproducible.

---

## Trial build of 12.3.1

Run on 2026-09-21 in a detached worktree of `alpha` at `1a0ad5b3d`: all 95 pins bumped,
`pnpm run setup --no-build`, the PPX built from source, every `lib/` wiped, then a clean root
build.

### Blocker: the PPX emits lambdas without arity

The first module fails:

```
PluginExtensionPoint_UiFragment.res:52  Signature mismatch … In module Delegate:
  let commandAuthorization: 'a => Reventless.Authorization.permission
  is not included in
  let commandAuthorization: command => Reventless.Authorization.permission
```

**Cause.** The compiler hands a PPX the syntax tree in the frozen format, and there a
function's arity is carried by a wrapper: `Function$(fun …)` with an `@res.arity N`
attribute (`ast_mapper_from0.ml`). A bare `Pexp_fun` comes back with *no* arity. The
compiler used to unify that with any arity. 12.3.1 enforces arity in module inclusion
(#8559), so the PPX's bare lambda no longer matches the spec's `command => permission`.

`reventless-ppx` emits exactly three lambdas, all in `AuthorizationInjection.ml`: the
constant `commandAuthorization = _ => <rule>`, the per-constructor `commandAuthorization`
switch, and the default `commandTransition = _ => Undeclared`. The PPX already *reads* the
`Function$` wrapper (`SidecarEmit`, `TranslationTable`, `TypeAnnotationInjection`). It just
never writes it.

**Fix.** A helper `arity1_fun ~loc pat body` wraps the `pexp_fun` in `Function$` with
`@res.arity 1`, and the three sites call it. `ast_mapper_from0.ml` is byte-identical in
12.3.0 and 12.3.1, so the fix is compatible both ways. It can land on 12.3.0 first, and that
makes the compiler bump a pure pin change. `sury-ppx` needed nothing.

### Results with the fixed PPX

| Check | Result |
|---|---|
| Clean root `pnpm run build` (all 13 steps) | ✅ 0 warnings, 0 errors |
| `pnpm test` | ✅ 427 suites, 4,626 tests |
| `test:projects` | ✅ 427 suites across 18 projects, none empty |
| `check:graphql`, `check:lifecycle`, `check:dcb-scope`, `check:outputs` | ✅ no drift |
| `format:res` | ✅ no `.res` file rewritten |

The two `publishedEvents declares …` warnings printed by the golden checks also appear on
`alpha` with 12.3.0. The compiler bump did not cause them.

**Tracked output that changes:** four `.res.mjs` files under `src/`, all caused by #8568. A
function with an optional argument that returns a closure now computes the default when the
outer function is called, not each time the closure runs:

- `rescript/pulumi-aws/…/AppSync_Resolver_Functions.res.mjs`: `resolveIds`, `batchGetItemsByIds`, `refsByIds`
- `reventless/aws/…/DcbEventLogStorage_DynamoDb_Runtime.res.mjs`: `read`, `append`, `readStream`
- `reventless/core/…/CommandGenerator_Callback.res.mjs`: `makeGenerateCommand`
- `reventless/seed-aws/src/ReventlessSeedAws.res.mjs`: `connect`

Every default involved is a literal (`[]`, `true`, `"."`) that the closure only reads, so
behaviour is the same. The only difference is that one `[]` is now shared across calls of
the closure. The bump commit must include these files, or `check:outputs` will show drift.

**Not verified:** a clean build of `reventless-host-shell`, the crash case, which lives in
the UI repo. #8482 describes that exact panic.

---

## 13.0.0: what changes for us

Changelog: [CHANGELOG.md on master](https://github.com/rescript-lang/rescript/blob/master/CHANGELOG.md).

### Removals: this repo's sources already comply

Checked across all 1,780 tracked `.res`/`.resi` files and 55 `rescript.json` files. There
are no hits for any of these:

| Removed in v13 | Hits |
|---|---|
| `Js.*` namespace (alpha.6) | 0 |
| `Belt` (moves to `@rescript/belt`, alpha.6) | 0 |
| `%re` (alpha.6) | 0 |
| uncurried `(. args) =>` syntax (alpha.1) | 0 |
| `Obj.*`, `Char`, `Array.unsafe_get`, `Int.Ref`, `incr`/`decr` (alpha.6) | 0 |
| `@get` / `@set` on object types; fields that become non-settable (alpha.6) | 0 |
| `@this` async form, `@taggedTemplate`, `%external` | 0 |
| `bsconfig.json`, `es6` module names, `external-stdlib` (alpha.1) | 0 |
| `rescript build -w`, `rescript-legacy` in scripts | 0 |

`%raw` (96 files) is still supported in v13. Node 20 support is dropped in alpha.5, which
doesn't affect us on 22.17.1.

### What blocks us: dependencies

1. **sury.** `sury@11.0.0` declares `peerDependencies: { rescript: "12.x" }`. Every spec and
   every state/command/event schema goes through sury and sury-ppx, so v13 has to wait for
   a sury release that supports it. Before that, **move from `11.0.0-rc.2` to `11.0.0`
   final**. That step is independent of the compiler bump and makes the eventual v13 step
   smaller.
2. **PPX format.** alpha.6 bumps the AST, CMI and CMT formats, but states that the
   *external PPX encoding stays compatible* ("magic numbers distinct from the frozen
   external PPX format"). If that holds in the final release, `reventless-ppx` (built on
   `ppxlib` 0.34) and `sury-ppx` need no rewrite. It is still the first thing to test on a
   v13 release candidate, because both PPXes run on every spec file.
3. **Changed compiler caches.** A v13 build cannot reuse `lib/` from 12.x (CMI/CMT format
   bump). Every `lib/` directory must be wiped. A stale `.cmi` produces
   "The value X can't be found" errors.
4. **`@rescript/std ^11.1.4`** in `rescript/ssh2` and `rescript/web` is the runtime package
   from the v11 era. Check whether either package still needs it. It should go before v13
   in any case.
5. **`@rescript/react ^0.13.1`** in the hybrid example's `seed-data`. The current version
   0.15.0 needs React 19.2 and `@rescript/runtime >=12`. Upgrade it separately.

### What we get

- `for…of` / `for await…of`, `break` / `continue` (alpha.4). These can replace several
  loops currently written in `%raw` and several recursive helpers.
- Dict spread `dict{...a, "k": v}` (alpha.4) and `Dict.concat*` (alpha.6).
- Source maps (alpha.6), useful for Lambda stack traces.
- `--prod` builds that skip dev dependencies (alpha.4), useful for the layer builder.
- Destructuring the rest of a record (alpha.5).

None of these is urgent enough to adopt an alpha compiler.

---

## Recommendation and order

1. **PPX: emit arity-carrying lambdas** (`fix(ppx)`, on 12.3.0). Add a PPX unit test that
   the injected `commandAuthorization` / `commandTransition` come out wrapped in
   `Function$`. Republish `reventless-ppx`: external consumers who move to 12.3.1 need the
   fixed binary, or every spec file fails to compile.
2. **Ship 12.3.1 in one commit:** 95 pins (peers relaxed to `^12.3.1`) and the four
   regenerated `.res.mjs` files. The trial needed nothing else. Mark the related fix note as
   resolved by 12.3.1. Then bump tools, UI and business, whose `^12.3.0` ranges already
   accept it, and build the host shell clean there.
3. **Move sury / sury-ppx to 11.0.0 final**, as a separate change.
4. **Remove `@rescript/std`** from `ssh2` / `web` if nothing needs it.
5. **v13: wait** for 13.0.0 final and a sury release that accepts it. Then do a trial build
   whose first check is that both PPXes still load. Reopen this analysis at that point.
