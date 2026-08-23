# Embedded Code Strings — Inventory and Improvement Options

Supersedes `appsync-resolver-js-as-strings.md` (2025), which concluded "no
meaningful alternative exists". That conclusion rested on two claims that are
wrong, so this is a recheck from scratch:

- *"`@aws-appsync/utils` is AppSync-internal magic — there is no real package
  to compile against."* False. `@aws-appsync/utils` is a real npm package
  published by AWS that ships TypeScript type definitions for exactly this
  purpose: authoring and type-checking resolver code locally before upload.
  The import specifier is still resolved by the AppSync runtime at execution
  time, but locally the package gives `tsc` everything it needs.
- *"All AWS IaC tools embed AppSync resolver code as strings."* Misleading.
  They all *upload* a string (the API accepts nothing else), but CDK and
  Amplify author resolvers as real `.ts`/`.js` files, type-check and lint them
  (`@aws-appsync/eslint-plugin` encodes the APPSYNC_JS restrictions), bundle
  with esbuild, and read the artifact at deploy time. The string is the wire
  format, not the source format.

The real question is therefore not "can the string be avoided" (it cannot) but
"can the *source of truth* be a syntax-checked file instead of a ReScript
template literal". It can — with trade-offs analysed below.

## Inventory

Three distinct categories, with different problems and different fixes.

### 1. APPSYNC_JS resolver code (the big one)

Code that executes inside AppSync's restricted JS engine. Must reach AWS as a
self-contained module string; only `@aws-appsync/utils` may be imported.

| File | Scale | Nature |
|---|---|---|
| [`AppSync_Resolver_Functions.res`](../../rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res) | 1 632 lines, ~40 templates, ~39 distinct `request`/`response` bodies | Deploy-time template library. Interpolates field/index/table names into DynamoDB expressions **and** conditionally splices whole code blocks (owner guard × retirement guard × sort × index variants) |
| [`QueryDbResolvers_AppSync.res`](../../reventless/aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res) | 2 templates + 23 call sites into the library | `Invoke` unit resolvers carrying dispatch metadata for the Pg query Lambda |
| [`QueryDbResolvers_Lambda.res`](../../reventless/aws/src/adapter/QueryDb/QueryDbResolvers_Lambda.res) | 2 templates | `Invoke` shims for Lambda-backed query fields |
| [`AppSync_Resolver_Retrying.res`](../../reventless/aws/src/adapter/Api/AppSync_Resolver_Retrying.res) | 2 small templates | Subscription request/response defaults, optional `setSubscriptionFilter` splice |
| [`AppSync_Resolver_Native.res`](../../reventless/aws/src/adapter/Api/AppSync_Resolver_Native.res) | 1 small template | Same, native-provider variant |
| [`Auth_ActiveRoleStore.res`](../../reventless/aws/src/adapter/Auth/Auth_ActiveRoleStore.res) | 1 template (`invokeCode`) | Identity-forwarding `Invoke` resolver |
| [`Geocoder_AwsLocation_Resolver.res`](../../reventless/aws/src/adapter/Geocoder/Geocoder_AwsLocation_Resolver.res) | 1 template | Plain `Invoke` resolver |
| [`Upload_Presign_S3.res`](../../reventless/aws/src/adapter/Upload/Upload_Presign_S3.res) | 1 template | Identity-forwarding `Invoke` resolver |
| [`AppSync_EventsApi.res`](../../reventless/aws/src/adapter/Api/AppSync_EventsApi.res) | API surface | *Accepts* a raw `codeHandlers: string` from the consumer — the un-checked-string problem exported as a public interface |
| [`CommandGenerator/*Resolvers_AppSync.res`](../../reventless/aws/src/adapter/CommandGenerator/) | call sites | Consume the library's `invokeCommandGenerator` / `invokeDcbMutation` / `invokeInboundTranslation` |

**How failures surface today.** Nothing checks these strings before `pulumi up`.
AppSync validates at resolver-create time and rejects with "The code contains
one or more errors" — a 15-minute CI deploy cycle (or ~1-minute warm local
preview, which however does not create resolvers) per syntax error. The file's
own comments document the scars: the `_owns` zero-arg-stub TS2554 rejection is
explained in three places; `@aws-appsync/no-try`, the no-loops rule, the
no-`String()` rule and the no-comparator-sort rule each live as prose comments
because no tool enforces them locally. The existing tests
([`AppSync_RetirementNarrowingTest.res`](../../reventless/aws/tests/AppSync_RetirementNarrowingTest.res),
[`QueryDbResolvers_AppSyncTest.res`](../../reventless/aws/tests/QueryDbResolvers_AppSyncTest.res))
assert **substrings** of the generated source — they catch a dropped guard, but
not a syntax error, an unbalanced brace from a bad splice, or a forbidden
construct.

**The deeper maintenance hazard** is not the strings per se but the
*combinatorial splicing*: `ownerScopedResultResponse` alone assembles a
function body from four optional fragments (`ownerPart`, `retiredPart`, the
`_live` call, the `_owns` stub), and two `const _exempt` declarations colliding
in one body is a live failure mode the code defends against in comments and a
dedicated test. Every new cross-cutting concern (owner scoping, retirement,
`includeRetired`) multiplied the fragment matrix.

### 2. Node.js Lambda entry points as strings

One remaining case:
[`ClonerRunner_Fargate.res`](../../reventless/aws/src/plugin/cloner/ClonerRunner_Fargate.res)
embeds a complete Lambda module (`entryPointCode`, ~25 lines of
`@aws-sdk/client-ecs` code) as a string fed to `Pulumi.Asset.stringAsset`.

This is a **solved problem elsewhere in the repo**:
[`Upload_Presign_S3.res`](../../reventless/aws/src/adapter/Upload/Upload_Presign_S3.res),
the [geocoder](../../reventless/aws/src/adapter/Geocoder/Geocoder_AwsLocation_Resolver.res),
[`Auth_ActiveRoleStore.res`](../../reventless/aws/src/adapter/Auth/Auth_ActiveRoleStore.res),
[`Platform_UIFragments_Lambda.res`](../../reventless/aws/src/adapter/Api/Platform_UIFragments_Lambda.res)
and [`PgQueryResolver_Builder.res`](../../reventless/aws/src/adapter/QueryDb/PgQueryResolver_Builder.res)
all moved their runtime logic into compiled `*_Ops.res` modules and reference
the built `.res.mjs` via `~entryPointModule` + `buildCodeArchive` (the split
that fixed the Frankenstein-SDK 502s and the Pulumi-in-runtime-graph
cold-start bug). The cloner runner simply predates the pattern.

### 3. `%raw` micro-snippets

[`Auth_Cognito.res`](../../reventless/aws/src/adapter/Auth/Auth_Cognito.res)'s
`_decodeJwtClaims` (a 10-line JWT payload decoder) and
[`AppSync_Resolver_Retrying.res`](../../reventless/aws/src/adapter/Api/AppSync_Resolver_Retrying.res)'s
`newOf0`/`newOf1`/dynamic-import externs. The repo already has a rule for
these — no `Obj.magic`/`%raw` in `.res`; untyped code goes in a companion
`.mjs` bound via `@module`. These are small grandfathered violations, listed
here for completeness.

## Recheck: could the resolver bodies be written in ReScript?

**No — and it is worth recording precisely why, because "it compiles to JS"
makes the idea perennially tempting.**

1. **The APPSYNC_JS subset excludes what the ReScript compiler emits.** The
   runtime rejects `for`/`for-of`/`for-in` and `while` loops, recursion,
   `try`, `++`/`--`, `String()`/`.toString()`, and comparator `sort()`
   callbacks (all documented from real deploy failures in
   [`AppSync_Resolver_Functions.res`](../../rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res)
   comments). ReScript's stdlib and its pattern-match/currying codegen use
   loops and recursion freely, and nothing in the compiler contract promises
   to stay inside any subset. A hello-world might compile clean today; a
   stdlib call or a compiler upgrade silently moves the output outside the
   subset, discovered only at resolver-create time.
2. **Only `@aws-appsync/utils` may be imported.** Any ReScript function
   touching `Belt`/`Core`/`Js` emits imports of ReScript runtime modules. A
   bundler could inline them — but then the bundled runtime helpers themselves
   hit restriction 1 (they contain loops).
3. **The parameterization is deploy-time, not compile-time.** Field names,
   index names, elevated groups and table names arrive per view when Pulumi
   runs. Compiled ReScript has no splice point; the template approach exists
   *because* of this. (The fix below keeps the values deploy-time but moves
   them into data instead of code.)

TypeScript does not have these problems because AWS maintains the toolchain
for exactly this target: types (`@aws-appsync/utils`), a lint ruleset encoding
the runtime restrictions (`@aws-appsync/eslint-plugin`), esbuild bundling
guidance, and a validation API (`aws appsync evaluate-code`, runtime
`APPSYNC_JS 1.0.0`).

## Improvement options

### Option A — validation harness over the existing templates (low effort, immediate)

Keep the ReScript templates; make CI prove every generated string is a valid
APPSYNC_JS module. Two layers, both cheap:

1. **Parse + execute in Jest.** A test suite in
   [`reventless/aws/tests/`](../../reventless/aws/tests/) instantiates every
   template across its parameter matrix (owner × retired × values-form × sort ×
   index — the matrix the substring tests already partially walk) and, for
   each string, builds a `vm.SourceTextModule` with a linker that resolves
   `@aws-appsync/utils` to a stub. The Jest setup already runs under
   `NODE_OPTIONS='--experimental-vm-modules'`, so this needs no new
   infrastructure. Parsing alone kills every unbalanced-splice and
   double-`const _exempt` class of bug; going one step further and *calling*
   `request(fakeCtx)` / `response(fakeCtx)` upgrades the substring assertions
   into behavioural ones (assert the returned DynamoDB request object, not the
   source text).
2. **Lint with `@aws-appsync/eslint-plugin`.** Write the instantiated strings
   to the scratch/tmp dir and run eslint with the plugin's base config over
   them (one devDependency + one script). This mechanises the restriction
   list currently maintained as comments — no-try, no loops, no `String()`,
   no comparator sort would have been caught locally in seconds.

Optionally, a deploy-pipeline job can call `aws appsync evaluate-code` against
the real runtime for the handful of templates with the hairiest splices —
that is the same validator resolver-create uses, moved before the deploy.

Option A does not touch the maintenance-hazard root cause, but it converts
"syntax error discovered 15 minutes into a deploy" into "test failure in
seconds", and it is entirely incremental.

### Option B — author resolvers as real files, parameterize via config injection (the structural fix)

The pattern CDK/Amplify users follow, adapted to this repo's deploy model:

1. **One `.ts` file per resolver family** under e.g.
   [`rescript/pulumi-aws/src/AppSync/`](../../rescript/pulumi-aws/src/AppSync/)`resolvers/`,
   written against `@aws-appsync/utils` types, linted by the eslint plugin,
   unit-tested directly in Jest (import the module, call
   `request`/`response`).
2. **Deploy-time values become data, not code.** Instead of interpolating
   `'#${idField} = :${idField}'`, the file reads a config object:
   ```js
   // prologue prepended by the ReScript side at deploy time:
   //   const __CONFIG__ = {"idField":"categoryId","index":"categoryId", ...};
   const c = __CONFIG__;
   query.expression = '#' + c.idField + ' = :' + c.idField;
   ```
   Runtime string-building of expressions is already what half the templates
   do (`'#' + key`, `values[':' + key]`), so this is proven inside the subset.
   A `declare const __CONFIG__` in a local `.d.ts` keeps `tsc` happy.
3. **Conditional fragments become runtime branches.** `if (c.ownerField)
   { …push filter… }` replaces the `ownerPart`/`retiredPart` string splicing —
   the double-`const _exempt` and TS2554-stub classes of bug become
   structurally impossible, because there is exactly one function body and it
   is checked as written. Dead branches ship in the uploaded string; the
   resolver code cap (~32 KB) is generous against these file sizes, and a
   build-time size assertion closes the gap.
4. **The ReScript side shrinks to plumbing:** read the file from the published
   package (precedent: `~entryPointModule` already resolves shipped `.mjs`
   files from `node_modules` at deploy time), JSON-encode the per-view config,
   prepend the prologue, hand the string to Pulumi exactly as today. The
   `Pulumi.Input.t<string>` wrapping and `Output.apply` interpolation for
   table names is unchanged.

Cost: a TypeScript toolchain (tsc + eslint, no bundler needed if each file
stays import-free apart from `@aws-appsync/utils`) inside an otherwise pure
ReScript package, and a migration of ~40 templates. The migration is
mechanical per template and can proceed door-by-door — the library's function
signatures (`getItemById`, `listAllItemsConnection`, …) stay stable while
their bodies switch from splicing to file-plus-config, so consumers
([`QueryDbResolvers_AppSync.res`](../../reventless/aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res)
and friends) never notice.

Templates that interpolate *structure* rather than values — `resolveIds`'s
`BatchGetItem` table map — work unchanged with config: computed keys
(`tables[c.tableName] = …`) are inside the subset (the current
`listAllItemsConnection` already computes keys with `values[':id' + i]`).

### Option C — checked template files with placeholder identifiers (not recommended)

Move each template into a `.js` file containing placeholder identifiers
(`__ID_FIELD__`), syntax-check it, and re-embed with string replacement at
build time. Rejected: the checked artifact is still not the shipped artifact
once conditional fragments are spliced in, so the guarantee evaporates exactly
where the bugs live. Option B gets the full guarantee for similar effort.

## Recommendation

Phased, each step independently shippable:

1. **Option A now** — the vm-module + eslint harness. Small, no restructuring,
   and it immediately covers *all* category-1 files including the small
   single-template adapters that will never justify migration.
2. **Option B for
   [`AppSync_Resolver_Functions.res`](../../rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res)**
   — the one file where the fragment-splicing matrix is a real ongoing hazard;
   migrate door-by-door behind stable signatures. The small `Invoke`-shim
   templates elsewhere can stay as strings under harness coverage; at three
   lines each, a `.ts` file per shim buys little.
3. **[`ClonerRunner_Fargate.res`](../../reventless/aws/src/plugin/cloner/ClonerRunner_Fargate.res)**
   — move `entryPointCode` to the established `*_Ops.res` +
   `buildCodeArchive` pattern (or minimally a shipped
   `ClonerRunner_EntryPoint.mjs` read as a `FileAsset`). Pure catch-up with
   existing repo convention.
4. **`%raw` snippets** — fold into the existing no-`%raw` rule's companion-
   `.mjs` pattern opportunistically when those files are next touched.
5. **[`AppSync_EventsApi.res`](../../reventless/aws/src/adapter/Api/AppSync_EventsApi.res)`.codeHandlers`**
   — once the harness exists, run consumer-supplied handler strings through
   the same parse+lint check at deploy time, so the public API stops accepting
   silently broken code.
