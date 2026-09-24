# Plan: every command-line tool reads its arguments one way

**Status:** ✅ Done (2026-09-23). C0–C5 landed in one commit; C6 is the release that carries it.
See *Where the implementation differs* at the end.<br/>
**Touches:** `rescript/node` (a new `NodeUtil.res`; `NodeProcess.onSignal`'s signature),
`reventless/spec` (a new `CliArgs.res` and its test), the fourteen command-line tools listed
below and their tests, and the two `onSignal` calls in
`reventless/local/src/LocalPlatformRegistry.res`. No runtime change to any platform.<br/>
**Consumer:** reventless-tools' command-line tools, which hand-roll the same parsing. They adapt
after the release that carries this, starting with `scripts/BootstrapApp.res`; nothing here
waits on them. **Adapted 2026-09-24** on spec `alpha.144`: `bootstrap:app`, `check:demos`,
`reventless-dev`, `reventless-codegen` and `create-app` all read argv through `CliArgs`.
`create-app` takes `reventless-spec` as a dependency for it, and spells `-y` out as `--yes`
before parsing, because `CliArgs` gives a short form to `-h` alone.

## Goal

Every command-line tool in this repository reads `process.argv` through Node's own
[`util.parseArgs`](https://nodejs.org/api/util.html#utilparseargsconfig), bound once in
`@reventlessdev/rescript-node`, with one shared layer that words the errors the way these tools
already word them and makes them all behave the same on `--help`, on a usage mistake and on a
bare invocation. No tool keeps a hand-written argument loop, and `rescript-node` keeps no
polymorphic variant.

## What is there today

Fourteen tools read `argv`, and each wrote its own parser. There is no argument library anywhere
in the repository, and `rescript-node` binds nothing from `node:util`. They fall into four
styles:

| Tool (bin) | Source | Style | Arguments | Parse tests |
|---|---|---|---|---|
| `deploy-app` | `reventless/aws/scripts/DeployApp.res` | loop → `result<args, string>` | `up`\|`down`, `--manifest`, `--stack`, `-h` | `DeployAppTest` |
| `bake-manifest` | `reventless/aws/scripts/BakeManifest.res` | loop → `result` | `--manifest`, `--since`, `--stack`, `-h` | `BakeManifestTest` |
| `provision-accounts` | `reventless/aws/scripts/ProvisionAccounts.res` | loop → `result` | `--file`, `--provider-id`, `--stack`, `-h` | `ProvisionAccountsTest` |
| `provision-admin` | `reventless/aws/scripts/ProvisionAdmin.res` | loop → `result` | `--email`, `--provider-id`, `--stack`, `-h` | `ProvisionAdminTest` |
| `provision-identity` | `reventless/aws/scripts/ProvisionIdentity.res` | loop → `result` | `--login-identifier`, `--name`, `--provider-id`, `--sign-up-mode`, `-h` | `ProvisionIdentityTest` |
| `prepare-accounts` | `reventless/spec/src/types/PrepareAccounts.res` | loop → `result` | `--file`, `-h` | `PrepareAccountsTest` |
| `trait-manifest` | `reventless/spec/src/generator/TraitManifestCli.res` | positional + `indexOf("--" ++ key)` | `<trait-package> --out`, `-h` | none |
| `certify-trait` | `reventless/spec/src/generator/CertifyTrait.res` | positional + `indexOf` | `<trait-package> --host --report --out`, `-h` | none |
| `graft-trait` | `reventless/spec/src/generator/GraftTrait.res` | positional + open-ended pairs | `<trait-package> --into --tests [--key value …]`, `-h` | none |
| `generate-plugin` | `reventless/spec/src/generator/PluginGenerator.res` | by index | `[--aws <namespace>] <srcDir>` | none |
| `generate-platform` | `reventless/spec/src/generator/PlatformGenerator.res` | by index | `<deploy-manifest.yaml>` | none |
| `emit-capabilities` | `reventless/local/src/EmitCapabilities.res` | by index | `<srcDir> [<compositionModule>]` | none |
| `check-lifecycle` | `reventless/spec/src/lifecycle/CheckLifecycleModel.res` | `Array.includes` at top level | `--update`, `--root <dir>`, `--stdin`, `--json`, `--reuse-sidecars` | model only |
| `check:graphql` | `scripts/CheckGraphqlContract.res` | `Array.includes` | `--update` | none |

`CheckGraphqlContract`'s `--disable-warning=ExperimentalWarning` is not one of its arguments.
It is a Node flag the script passes to a child process, and it stays out of the option table.

### What the hand-rolling hides

Fourteen parsers have given the same questions fourteen answers, and several of the answers are
wrong:

- **A string flag swallows the next flag as its value.** `DeployApp`'s
  `(Ok(a), "--manifest", Some(v))` arm takes whatever token follows, so
  `deploy-app up --manifest --stack try` deploys with the manifest `"--stack"`. The loop parsers
  written the same way share this.
- **The trait tools never look at what they did not ask for.** `indexOf("--" ++ key)` finds the
  flags it wants and ignores the rest. A typo in a required flag is reported as the wrong thing:
  `certify-trait pkg --hots api --report r.json --out o` answers *"--host, --report and --out are
  all required"* and never mentions `--hots`. A flag it does not ask for is not reported at all,
  and a missing value takes the next token, whatever that is.
- **`--flag=value` works nowhere.**
- **The same mistake is worded differently in each tool, and ends differently.** How they behave
  today:

| | `-h` / `--help` | A usage mistake | A bare invocation |
|---|---|---|---|
| The six loop parsers | usage → stdout, exit 0, anywhere in argv | `<bin>: <message>` → stderr, exit 1, no usage | runs on defaults, except `deploy-app`: *"say `up` or `down` (--help for more)"*, exit 1 |
| The three trait tools | usage → stdout, exit 0, **only as the first argument** | `<bin>: <message>` → stderr, exit 1 | usage → **stdout**, exit 1 |
| `generate-plugin`, `generate-platform`, `emit-capabilities` | **not recognised**: `generate-plugin -h` takes `-h` as its `<srcDir>` | a bare `Usage: …` line → stderr, exit 1, no `<bin>:` prefix | the same usage error |
| `check-lifecycle`, `check:graphql` | not recognised | only a missing `--root` value is reported (exit 1); anything else is ignored | runs |

  Every tool also exits 1 when it *ran and failed*: drift found, a provisioning call refused. So
  exit 1 cannot tell a caller whether the tool was misinvoked or did its job and said no.

## Design

Two layers with different jobs. `rescript-node` binds Node and holds no policy. `spec` holds the
policy these tools share: how a mistake on the command line is worded, and what a tool does on
`--help`, on a usage mistake and on a bare invocation.

### The binding: `NodeUtil` in `rescript-node`

No polymorphic variants. Node's string enums are regular variants whose constructors compile to
the exact strings Node reads and writes, through `@as`:

```rescript
/** Bindings for `node:util`. `parseArgs` is stable from Node 20. */

/** An option's `type`. */
type optionType =
  | @as("string") String
  | @as("boolean") Boolean

type optionConfig = {
  @as("type") type_: optionType,
  short?: string,
  multiple?: bool,
}

type config = {
  args?: array<string>,
  options: dict<optionConfig>,
  strict?: bool,
  allowPositionals?: bool,
  tokens?: bool,
}

/** A token's `kind`. The constructor names avoid `Option`, which would read as the
    standard library module at every use site. */
type tokenKind =
  | @as("option") Flag
  | @as("positional") Positional
  | @as("option-terminator") Terminator

type token = {
  kind: tokenKind,
  index: int,
  name?: string,
  rawName?: string,
  value?: string,
  inlineValue?: bool,
}

/** `values` mixes strings, booleans and arrays under one object, so it is abstract and
    read through the typed accessors below. */
type values

type parsed = {values: values, positionals: array<string>, tokens?: array<token>}

@module("node:util") external parseArgs: config => parsed = "parseArgs"

@get_index external string: (values, string) => option<string> = ""
@get_index external bool: (values, string) => option<bool> = ""
@get_index external strings: (values, string) => option<array<string>> = ""
```

Left out on purpose:

- **`default`.** Its value is a string, a boolean or an array depending on the option, so a
  truthful type for it is awkward, and `Option.getOr` at the call site does the same job.
- **`allowNegative`.** It arrived in Node 22.4, and nothing here needs `--no-x`.

### The shared layer: `Reventless.CliArgs` in `spec`

`spec` is the one package every one of the fourteen can reach. `aws`, `local` and the root
scripts all depend on it, and seven of the tools live in it. The layer calls `parseArgs` with
`strict: false, allowPositionals: true, tokens: true` and reads the tokens itself. Strict mode is
not used because its errors carry the offending argument only inside English message text, and
the wording the tests below pin has to be reproduced exactly.

The contract:

| Case | Result |
|---|---|
| An option nobody declared | `Error("unknown argument \"<rawName>\"")` — the first in argv order |
| A string option with no value, or whose value is itself flag-shaped (`--x --y`) | `Error("<rawName> needs a value")` |
| Positionals | returned in order. The tool decides how many it takes; `CliArgs.extra` words a surplus one as `unknown argument "<value>"` |
| A **leading** bare `--` | dropped, then parsing continues. Package managers forward it (`pnpm run check:lifecycle -- --reuse-sidecars` is in this repository's CI); anywhere else it ends options, as POSIX says |
| `pairs: true` | undeclared `--key value` becomes `(key, Text(value))`, and undeclared `--key` with no following value becomes `(key, Present)`, in argv order. This is `graft-trait`'s semantics, reconstructed from token order: non-strict `parseArgs` types an undeclared option as a boolean and emits its value as the next positional token |

`Text | Present` is a regular variant, like everything else here. The layer returns a record
with typed accessors (`CliArgs.string`, `.bool`, `.strings`, `.positionals`, `.pairs`), so no
tool touches `NodeUtil.values` directly.

### One behaviour for every tool

The same situation ends the same way in every tool, so a person learns it once and a caller can
act on the exit code:

| Situation | Output | Exit |
|---|---|---|
| `-h` or `--help` **anywhere** in argv | the tool's usage → **stdout** | **0** |
| A usage mistake: an unknown argument, a missing value, a missing required positional or subcommand, a surplus positional | `<bin>: <message>`, a blank line, then the usage → **stderr** | **2** |
| A bare invocation | not a case of its own. A tool that needs nothing runs, and a tool that needs something reports the first missing thing as a usage mistake | 0, or 2 |
| The tool ran and failed (drift found, a call refused) | as today | **1**, unchanged |

Four rules sit behind the table:

- **Help is implicit.** `CliArgs` declares `-h`/`--help` for every tool, so no tool declares it
  and none can forget it. This is how the three generators and the two checks gain it.
- **Help wins.** If `-h` or `--help` appears, the usage is printed and nothing else is reported,
  even when other arguments are wrong. Someone asking what a tool takes should get the answer,
  not an error about the arguments they were unsure of.
- **Exit 2 means misinvoked.** POSIX utilities use 2 for a usage error, and it separates "you
  called me wrong" from "I ran and the answer is no". Callers in this repository only test for
  non-zero (`prebuild`, CI), so none of them changes.
- **The usage follows the error on stderr.** The error says what went wrong and the usage says
  what would be right, on the stream a script's caller watches. A usage mistake never writes to
  stdout, which on `check-lifecycle --json` is data.

Each tool keeps its own usage text, and its first line becomes `Usage: <bin> …`. It lives in
`CliArgs.run`:

```rescript
/** Parse, then either print usage and exit 0, or report a usage mistake with the usage and
    exit 2, or hand the parsed arguments to `main`. `main`'s own failures keep their exit 1. */
let run: (~bin: string, ~usage: string, ~parse: array<string> => result<'args, string>,
  ~main: 'args => promise<unit>) => promise<unit>
```

The six tested tools keep their `parseArgs: array<string> => result<args, string>` and their
`help` field, because their tests assert `parseArgs(["-h"])` returns `Ok({…, help: true})`.
`run` reads that field. The tools only stop wiring the help path by hand in `main`.

### `NodeProcess.onSignal` becomes a regular variant

It is the one polymorphic variant left in `rescript-node`:

```rescript
// today
external onSignal: ([#SIGINT | #SIGTERM | #SIGHUP], unit => unit) => unit = "on"

// after
type signal =
  | @as("SIGINT") SIGINT
  | @as("SIGTERM") SIGTERM
  | @as("SIGHUP") SIGHUP

@val @scope("process")
external onSignal: (signal, unit => unit) => unit = "on"
```

At runtime it is still the same string Node receives. It keeps the property the polymorphic
variant was chosen for, that a misspelt signal is a compile error. It is a **breaking change to a
published signature**, so the release marks it as one. It has two callers, both in
`LocalPlatformRegistry.res` (`#SIGINT` → `SIGINT`, `#SIGTERM` → `SIGTERM`), and they change in the
same commit. Neither this repository's other packages nor reventless-tools call it; the latter
binds `process.on` itself.

## What stays and what changes

**Stays:** every argument vector the fourteen accept today, and the exact error text the six
parser tests pin (`unknown argument "--stak"`, `--provider-id needs a value`, and so on).

**Changes**, each on purpose and each with a test:

| Change | Where | Why it is safe |
|---|---|---|
| A flag-shaped value is refused (`--manifest --stack try`) | every tool that takes a string option | It never did what the user meant. No test or caller in this repository relies on it |
| An unknown flag is refused | trait tools, `check-lifecycle`, `check:graphql`, the generators | Today a typo runs silently. Callers are inventoried in C0 before this lands |
| `--flag=value` is accepted | everywhere | Purely additive |
| `generate-plugin <srcDir> --aws <ns>` (flag after the positional) is accepted | `generate-plugin` | Today `--aws` there is silently ignored. The existing order keeps working |
| Every tool takes `-h`/`--help`, anywhere in argv | the generators and the checks gain it; the trait tools stop requiring it first | Additive. `generate-plugin -h` stops generating into a directory called `-h` |
| A usage mistake exits **2**, not 1, and prints the usage after the message | all fourteen | Every caller here tests for non-zero only |
| A usage mistake says `<bin>: …` | `generate-plugin`, `generate-platform`, `emit-capabilities` | Their bare `Usage:` lines were the only unprefixed errors |
| A bare invocation of a trait tool is a usage mistake on stderr, exit 2 | the three trait tools | It printed the usage to stdout with exit 1, which read as success-shaped output from a failure |
| `deploy-app` with no subcommand is a usage mistake (exit 2, usage follows) | `deploy-app` | Same message and exit status as any other missing argument |
| `NodeProcess.onSignal` takes a `signal`, not a polymorphic variant | `rescript-node`; two calls in `LocalPlatformRegistry` | Marked breaking. No caller outside this repository |

### Contracts that must not move

These tools are called from outside the code that defines them:

- **`generate-plugin [--aws <namespace>] <srcDir>`** runs in the `prebuild` of every plugin
  package, including this repository's examples and every generated app.
- **`generate-platform <deploy-manifest.yaml>`** and **`emit-capabilities <srcDir>
  [<compositionModule>]`** run in platform builds.
- **`check-lifecycle --root <dir> --reuse-sidecars --json`** is how reventless-tools' editor
  extension reads lifecycle coverage. `--reuse-sidecars` is also passed by this repository's CI,
  behind a bare `--`.

Each gets a test in C0 that runs its exact invocation and has to pass unchanged in C4 and C5.

## Phases

Internal dependencies are `workspace:*` (`aws` and `local` on `spec` and `rescript-node`,
`spec` on `rescript-node`). So every phase builds against the binding in this repository, and
**one release at the end** carries all of it, with no intermediate publish.

### C0 — Pin the eight untested tools first

Extract each untested tool's parsing into a `parseArgs: array<string> => result<args, string>`
function that keeps its **current** logic, the shape the six tested tools already have. Then
write tests against it. They pin today's accepted forms and the four contracts above, *not* the
defects in the table above or today's help, error and exit behaviour: those change on purpose,
and their tests are written in C2–C5 against the new behaviour. Inventory every caller of the
trait tools, the generators and the two checks (package scripts, CI, examples, `traits/`) before
any of them becomes strict, and confirm that none tests for exit 1 specifically rather than for
non-zero.

**Signed off by:** all fourteen tools have a parse test, and all of them pass against the
unchanged parsers.

### C1 — `rescript-node`: `NodeUtil`, and `onSignal` off its polymorphic variant

The `NodeUtil` binding above, and `NodeProcess.onSignal` taking the new `signal` type. The two
calls in `LocalPlatformRegistry.res` change in the same commit, so the tree compiles at every
commit. `rescript-node` has no test harness and does not grow one for this: C2's tests call
`parseArgs` through the binding and are its evidence, and `onSignal` is covered by the compiler
and by `LocalPlatformRegistry`'s existing tests.

**Signed off by:** `rescript-node` contains no polymorphic variant.

### C2 — `CliArgs` in `spec`, with its test

`parse` against the contract table, case by case. That includes the leading `--`, the `pairs`
reconstruction against `graft-trait`'s current semantics, and one test per wording the six tools
use. Then `run` against the behaviour table: help anywhere prints usage to stdout and exits 0,
help wins over an unknown argument, a usage mistake writes `<bin>: <message>` and the usage to
stderr and exits 2, stdout stays empty on a usage mistake, and `main`'s own failure still exits 1.
`run` takes the exit function as a parameter in its tests, so they assert the code without
ending the test process.

### C3 — The six result parsers

Swap the bodies of `DeployApp`, `BakeManifest`, the three `Provision*` tools and
`PrepareAccounts` to `CliArgs.parse`, and their entry points to `CliArgs.run`. `DeployApp`'s
`up`/`down` becomes its first positional, a second one becomes `CliArgs.extra`, and a missing
one becomes a usage mistake instead of its own message.

**Signed off by:** their six test files are **unchanged** and green. Only then are the new tests
added: a flag-shaped value is refused, `--x=v` is accepted, and help wins over a bad argument.

### C4 — The trait tools and the generators

`trait-manifest`, `certify-trait`, `graft-trait` (`pairs: true`), `generate-plugin`,
`generate-platform`, `emit-capabilities`, all through `CliArgs.run`. The trait tools lose their
help-only-when-first check, and the generators gain `-h`/`--help` and the `<bin>:` prefix.

**Signed off by:** C0's contract tests pass unchanged, and every example still builds through
`generate-plugin` in its `prebuild`.

### C5 — The two checks

Parse once at the top of `check-lifecycle` and `check:graphql`, and thread the values through
instead of calling `NodeProcess.argv->Array.includes` wherever a flag is needed.
`check-lifecycle`'s module already keeps `main` off the top level (see its test), so the parsed
arguments go in there. Its drift and coverage failures keep exit 1; a usage mistake is now 2.

**Signed off by:** `check-lifecycle --root <dir> --reuse-sidecars --json` writes the same JSON as
before, and CI's `check:lifecycle -- --reuse-sidecars` still reuses sidecars.

### C6 — Release

One conventional-commit release carries C1–C5. The `onSignal` change is marked breaking
(`feat(node)!:` with a `BREAKING CHANGE:` footer naming the new `signal` type), so the changelog
says what a caller has to rewrite. Downstream tools adapt from this release.

## Decisions

| # | Decision | Leaning |
|---|---|---|
| **D1** | Where does the binding live? | **`rescript-node`, as `NodeUtil`.** It is Node's standard library, and every tool already depends on the package |
| **D2** | Polymorphic variants for `type`, the token kind, and `CliArgs`' pair value? | **No: regular variants with `@as`**, which compile to the same strings Node uses |
| **D3** | Where does the wording live? | **`spec`, as `Reventless.CliArgs`.** Every tool can reach it and `rescript-node` stays policy-free. Per-tool translation was the alternative, and that is the fourteen-copies problem again |
| **D4** | Strict mode or tokens? | **Tokens, non-strict.** Strict mode's errors name the argument only in prose, and the six pinned messages must survive word for word |
| **D5** | Refuse a flag-shaped value? | **Yes.** It is the one change here that fixes a wrong answer rather than an inconsistency |
| **D6** | Drop a leading bare `--`? | **Yes, and only a leading one.** This repository's own CI depends on it |
| **D7** | `graft-trait`'s open-ended `--key value`: keep it, or change it to `--set key=value`? | **Keep it.** The tokens carry enough to reconstruct it exactly, and the bin's interface does not move |
| **D8** | Does `NodeProcess.onSignal` leave its polymorphic variant in this release? | **✅ Decided 2026-09-23: yes.** It is a regular `signal` variant, the release marks it breaking, and its two callers change with it |
| **D9** | One behaviour for help, a usage mistake and a bare invocation across all fourteen? | **✅ Decided 2026-09-23: yes**, owned by `CliArgs.run`. See *One behaviour for every tool* |
| **D10** | Which exit code for a usage mistake? | **2.** It is the POSIX convention, and it lets a caller tell a misinvocation from a run that failed (1). Nothing here tests for 1 specifically, which C0 confirms |
| **D11** | Does `--help` win over a bad argument? | **Yes.** The person asking what a tool takes is the one least sure of their arguments |

## Open questions

None open. The two raised with the first draft are settled as D8 and D9.

## Acceptance

- No tool reads `NodeProcess.argv` except through one `CliArgs.parse` call. A grep for
  `NodeProcess.argv`, `indexOf("--"` and `Array.includes("--` over the fourteen sources returns
  only those call sites.
- `rescript-node` contains no polymorphic variant. A grep for `[#` over `rescript/node/src`
  returns nothing.
- Every one of the fourteen answers `-h` and `--help` with its usage on stdout and exit 0, and a
  usage mistake with `<bin>: <message>` and the usage on stderr and exit 2. One test per tool
  asserts both.
- The six original parse-test files are byte-for-byte unchanged and green.
- C0's contract tests are green before and after. Every example's `prebuild` runs
  `generate-plugin` as it did, and CI's `check:lifecycle -- --reuse-sidecars` still reuses
  sidecars.

## Where the implementation differs

In plain words: the plan held, and seven details came out differently once the code was written.

- **`run` takes the tool's command line as one record.** Each tool exports
  `cli: CliArgs.cli<args> = {bin, usage, parse}` and its `main` is
  `CliArgs.run(cli, args => …)`. The record is what the per-tool tests hand to `CliArgs.observe`,
  which runs a command line without a process and reports stdout, stderr, the exit code and
  whether `main` was reached. That is how "one test per tool" asserts help and a usage mistake
  without spawning fourteen processes.
- **Help is read off argv, not off each tool's `help` field.** `run` is generic over the tool's
  argument type, so it cannot read a field of it. `CliArgs.asksForHelp` looks for `-h`/`--help`
  before any `--` that ends the options, which is also what lets help win over a bad argument.
  The six tools keep their `help` field, filled by `CliArgs.help`, so their tests still pass
  unchanged.
- **A bare `--` is not forwarded by pnpm 10.** `pnpm run check:lifecycle -- --reuse-sidecars`
  reaches the script as `--reuse-sidecars` alone. A leading `--` is still dropped (D6): npm and
  `node run.mjs -- …` do forward it, and dropping it costs nothing.
- **`check-lifecycle` never took `--stdin`.** The inventory table listed it, but that `--stdin`
  is an argument the check passes to `rescript format` in a child process.
- **`provision-admin` without `--email` is a usage mistake.** It moved from `run` into the
  tool's `cli.parse` (`parseRequest`), so it exits 2. `parseArgs` itself still returns
  `Ok` with no address, so its pinned tests are unchanged.
- **Two small helpers joined `CliArgs`:** `atMost(n)` refuses the first positional past `n`
  as `unknown argument "<value>"`, and `noPositionals` is `atMost(0)`. `extra` is still there
  for a tool that reads its positionals itself (`deploy-app`).
- **`check:graphql`'s test needed a home.** The root `scripts/` package gained a `tests/`
  folder (a dev source in the root `rescript.json`) and a `scripts` jest project, and the
  script's top-level call moved into `scripts/check-graphql-contract.mjs`, as the other tools'
  wrappers already do. The generators and the trait tools lost their top-level calls the same way.

A boolean given a value (`--update=yes`) is refused as `--update takes no value`. The plan's
contract table did not mention it; without it, Node puts the string `"yes"` where a boolean is
expected.

### Checked beyond the tests

- Every example's `generate`, `generate:platform` and `emit-capabilities` wrote byte-for-byte what
  the previous build of the same tools wrote, run against the same inputs.
- `check-lifecycle --root examples/online-shop-hybrid --reuse-sidecars --json` wrote the same
  44,588-byte document as before, and `pnpm run check:lifecycle -- --reuse-sidecars` behaved as
  before.
- `pnpm run check:graphql` and `pnpm run check:traits` pass. The second drives `trait-manifest`,
  `graft-trait` (with its open-ended `--key value` pairs) and `certify-trait` against every
  specimen.
- Every caller of the tools was inventoried: package scripts, CI, `scripts/check-trait-pack.mjs`,
  the examples, the traits' READMEs and reventless-tools' editor extension. None tests for exit
  1 specifically.
