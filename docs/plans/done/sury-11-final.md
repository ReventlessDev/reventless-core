# Plan: sury 11.0.0-rc.2 → 11.0.0

**Status:** ✅ Done 2026-09-21 (Steps 1–3 and 5; Step 4 follows the push). A trial build was first run on 2026-09-21 in a detached worktree of `alpha`
(at `ea1ce3772`, ReScript 12.3.1) against the published `sury@11.0.0` / `sury-ppx@11.0.0`:
every check is green after edits to 13 files (7 in `src`, 6 in tests).<br/>
**Background:** [sury-11-migration.md](sury-11-migration.md) (the move to 11-alpha),
[rescript-version-upgrade.md](../../analysis/done/rescript-version-upgrade.md) (sury's
`rescript: 12.x` peer range is also what blocks ReScript 13).

## In plain words

sury is the library that turns our ReScript types into runtime schemas: it decodes every
command, event and state, and generates the JSON Schema that the GraphQL and MCP layers are
derived from. We are on the last release candidate but one (`rc.2`). `rc.3` renamed most of
the API. `11.0.0` final (2026-09-12) adds six commits on top of `rc.3`: new schemas, a
change to nullable union arms (below), and an internal rewrite of how operations are
dispatched. None of them renames anything further.

The upgrade is small for us, because most of our code reaches sury through `sury-ppx` and a
few helpers. It needs:

- two function renames (38 call sites, 32 of them in tests),
- the new nominal format types handled in four semantic types and two JSON-string helpers,
- one deliberate choice: `DateTime` switches to `S.utcDateTime`, so that it keeps rejecting
  timestamps with an offset.

## Words used here

- **`sury-ppx`**: the compiler plugin that turns `@schema type …` into a sury schema. It
  moves in lockstep with `sury`.
- **Nominal format type**: sury 11 now gives each string format its own type, for example
  `@unboxed type email = Email(string)`. At runtime it is still a plain string, but the
  compiler no longer lets it pass as `string` without a coercion (`:>`) or the constructor
  (`S.Email(s)`).

## What changed upstream that reaches us

From the [rc.3 release notes](https://github.com/DZakh/sury/releases/tag/v11.0.0-rc.3) and
the [rc.3 → 11.0.0 compare](https://github.com/DZakh/sury/compare/v11.0.0-rc.3...v11.0.0):

| Change | Effect here |
|---|---|
| `S.decodeOrThrow(~from, ~to)` → `S.convertOrThrow(~from, ~to)` | 26 call sites (3 in `src`) |
| `S.toJSONSchema` → `S.toInputJSONSchemaOrThrow` | 12 call sites, all in tests |
| Format schemas are nominal (`S.email: S.t<S.email>`, likewise `uri`, `isoDate`, `isoDateTime`, `jsonString`) | `Email`, `Url`, `CalendarDate`, `DateTime` grammars; `Util_Sury.toJsonString` / `fromJsonString`; `PolicyDocument.fromJsonString` |
| `S.isoDateTime` accepts any RFC 3339 offset; the old Z-only grammar is `S.utcDateTime` | `DateTime` must move to `S.utcDateTime` or it starts accepting `+02:00` |
| JS export names: `float` → `number`, `int` → `int32`, `bool` → `boolean`; compiled code imports `"sury"`, not `"sury/src/S.res.mjs"` | ~78 tracked `.res.mjs` files are regenerated. The source is unaffected. Lambda entry points already import bare `"sury"` (`DcbCommandTopicEntryPoint.mjs`), so the layer resolves it |
| `S.Error` is a real `Error` (`name: "SuryError"`) | No change in behaviour: it still carries `RE_EXN_ID: "S.Exn"`, so `\| S.Exn(e)` and `Util_Sury.exnMessage` still match. Checked by a probe in the trial |
| Error `path` is an array, messages use dot-paths (`Failed at user.tags[2]: …`) | No test or golden depends on the old text |
| `S.string→S.number` now rejects `""` (was `0`) and trims | No string-to-number schemas found |
| `S.unknown` JSON Schema is `{}`; `S.meta` examples are validated | `check:graphql` shows no drift |
| 11.0.0 (DZakh/sury PR 439): a `null`/`undefined` arm converted to a type that cannot hold it is dropped. `S.optional(S.number).with(S.to, S.string)` now rejects `undefined` instead of producing `"undefined"`. An optional record field encoded into a dict still leaves the key out | The area of our earlier optional-union bugs. Carriers (`S.json`, `S.jsonString`, `unknown`) keep the arm, and that is how commands, events and state reach JSON. All suites pass, but watch the deploy check (Step 4) |
| 11.0.0 (DZakh/sury PR 440): operations are dispatched without a separate compile step | Internal. Covered by the full test run |

Nothing we use was removed without a replacement. `S.json` is now typed `S.t<S.json>`, but
`S.json = JSON.t`, so it is the same type.

## Trial build: results

After the edits in Step 2:

| Check | Result |
|---|---|
| Clean root `pnpm run build` | ✅ 0 warnings, 0 errors |
| `pnpm test` | ✅ 427 suites, 4,626 tests |
| `test:projects` | ✅ none empty |
| `check:graphql`, `check:lifecycle`, `check:dcb-scope`, `check:outputs` | ✅ no drift |

The warnings printed by the golden checks (`publishedEvents declares …`, `Say which it
references with @ref`) also appear on `alpha`.

## Steps

### 1. Pins

- `sury` `11.0.0-rc.2` → `11.0.0` (37 × `dependencies`) and `sury-ppx` (30 ×
  `devDependencies`, 6 × `dependencies`), across 37 `package.json` files. No package declares
  sury as a peer.
- `pnpm install`. The lockfile diff should contain only sury.

### 2. Source edits (all found by the trial build)

| File | Edit |
|---|---|
| `reventless/spec/src/util/Util_Sury.res` | `toJson`: `decodeOrThrow` → `convertOrThrow`. `toJsonString`: coerce the result `(… :> string)`. `fromJsonString`: wrap the input `S.JsonString(str)` |
| `reventless/interop/src/ExportMeta.res` | `decodeOrThrow` → `convertOrThrow` |
| `rescript/pulumi-aws/src/IAM/PolicyDocument.res` | `fromJsonString`: `S.JsonString(policyString)->S.convertOrThrow(…)` |
| `reventless/spec/src/semantic/Email.res` | `grammar = (S.email :> S.t<string>)` |
| `reventless/spec/src/semantic/Url.res` | `grammar = (S.uri :> S.t<string>)` |
| `reventless/spec/src/semantic/CalendarDate.res` | `grammar = (S.isoDate :> S.t<string>)` |
| `reventless/spec/src/semantic/DateTime.res` | `grammar = (S.utcDateTime :> S.t<string>)`, and the module doc updated to match. **Grammar switch**, see Step 3 |
| 6 test files (`ResolvedOutputsTest`, `SuryToJsonSchemaTest`, `ResourceTest`, `PluginSpecExperiment`, `PluginStructureTest`, `PsAnnotatedView`) | the two renames |
| `reventless/spec/src/semantic/Money.res` | the comment that names `11.0.0-rc.2` |

Then `pnpm run format:res`, and commit the regenerated `.res.mjs`.

### 3. Keep the `DateTime` contract

`DateTime` documents "a UTC ISO-8601 instant". Keeping it on `S.isoDateTime` would silently
widen it to any offset. It moves to `S.utcDateTime`, and its module doc names the new binding.
The contract was already under test: `reventless/spec/tests/DateTimeTest.res` has
*"rejects an offset — instants are stored in UTC"*, which would fail on `S.isoDateTime`.
No new test was needed.

Accepting offsets would be a separate decision, and the stored form would still have to be
normalised to UTC.

### 4. Deploy check

The generated code now imports from the `"sury"` package entry point, not from
`sury/src/S.res.mjs`. The layer already serves that entry point, but only a deployed Lambda
proves it. Run one deploy of the hybrid example to the alpha stack after the push, and watch
one command round-trip and one projection. (CI deploys the hybrid example on every push to
`alpha`.)

### 5. Close out

- Update the Backlog [rescript-13-upgrade.md](../Backlog/rescript-13-upgrade.md): its step 1 is
  done. The remaining blocker there is a sury release whose peer range accepts ReScript 13
  (11.0.0 still says `rescript: 12.x`).
- `git mv` this plan to `done/` in the commit that lands Steps 1–3.

## Commit shape

Steps 1–3 and 5 form one `fix(deps): update sury to 11.0.0` commit: pins, lockfile, source
edits, regenerated `.res.mjs`, and this plan moved to `done/`.
Step 4 happens after the push.
