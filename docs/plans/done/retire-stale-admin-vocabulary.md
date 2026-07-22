# Retire the stale "Admin" vocabulary for platform-owned resources

**Status:** DONE (2026-07-22). All four tiers executed. Target name: **`Platform`**.
**Owner:** Martin

## Outcome

`Platform_Admin.res`'s `let name` is now bound to `Platform_Admin_Structure.pluginId`
(`"Platform"`) rather than a literal, so the resource names and the model identity cannot
drift apart again. Deployed identities move `Admin*` → `Platform*`:
`PlatformDcbEventLog`, `PlatformDcbCmdTopic`, `PlatformEventColl`, and the DCB event topic.

**Target-name decision — `Platform`, collision check clean.** Live tables at decision time
were `AdminDcbEventLog-f9850de`, `AdminDcbEventLog-faf285c` and
`PlatformInspectorDcbEventLog-df92f15`. There is no live `PlatformDcbEventLog`; the business
repo's mentions of that name are stale prose for the Inspector's own table
(`PlatformInspector.pluginName = "PlatformInspector"`, a distinct prefix). The "Unverified"
item in the original plan is therefore resolved.

**Timing window was open:** both `AdminDcbEventLog` tables held **0 items**, so the table
replacement cost nothing. This is a **wipe + redeploy**, not a migration (standing alpha rule).

### What changed per tier

| Tier | Change |
|---|---|
| 1 | `~comp="Admin"` log labels in `Platform_Admin_Callback` and `local/Platform.res` now bind `pluginId` |
| 2 | `AdminApi.res` → `Platform_AdminApi.res`; `Admin_Callback.res` → `Platform_Admin_Callback.res`; `AdminEventCollectorEntryPoint.mjs` → `EventCollectorEntryPoint.mjs` |
| 3 | MCP `pluginName` bound to `pluginId` in both `Platform_Admin.res` and `MCP_Lambda.res` |
| 4 | `let name` bound to `pluginId`; every `"AdminDcbEventLog"` dispatch-key literal derived via `ComponentType.name(DcbEventLog)` |

Also renamed the internal `AdminEventCollector` / `AdminRuntimeBuilder` module bindings, and
the synthetic `fakePluginDefinition` id/name — including its **hand-written JSON twin** in
`PluginRuntime_Builder.res`, which nothing compares against but must stay byte-aligned.

### Deviations from the plan as written

- **The `.mjs` became `EventCollectorEntryPoint.mjs`, not `Platform*`.** Its own header states
  it is "shared between the platform and every per-plugin EventCollector Lambda" and is
  plugin-agnostic — a `Platform` prefix would have recreated the same class of drift the plan
  exists to remove. The hardcoded path string at `PluginRuntime_Builder.res` moved with it.
- **The two `.res` files took the `Platform_` prefix rather than dropping "Admin"**
  (`Platform_AdminApi`, `Platform_Admin_Callback`), matching the un-renamed sibling
  `Platform_Admin.res` / `Platform_Admin_Structure.res`. `PlatformApi.res` was rejected because
  `PlatformApi` is already the split-mode AppSync source-API resource name.
- **`${serverName}-admin` (MCP server name) was left alone** — the plan asked for a decision.
  That suffix is the privilege sense, matching the Cognito group, not the plugin name.
- **One extra dispatch-key site the plan did not list:** `local/tests/PluginEventDecodeTest.res`
  hardcoded `"AdminDcbEventLog"`. Now derived from the same constant.
- Fixed a pre-existing warning-27 (`unused variable owner`) in `LocalEventLogStorage.res` from
  commit `a440d4f82`, to satisfy the zero-warnings rule.

### Verification

- Full build: **zero warnings**.
- `reventless/core`: 49 suites / 518 tests pass. `reventless/aws`: 21 suites / 280 tests pass,
  including **`Auth_CognitoTest`**. Root runner: 1101 tests pass, 0 test failures.
- **`CommandAuthorizationTest` green**; the authz group `"Admin"` is untouched — the diff
  contains zero `AllowGroups` / `group:` / `cognito_groups` lines, and every surviving
  `"Admin"` literal under `reventless/*/src` is an authz-group site.
- 4 root suites fail to *load* (`online-shop-hybrid` Extension/ExtensionPointMapping GWT,
  "Cannot use import statement outside a module"). **Verified pre-existing** — they fail
  identically on a stashed HEAD tree. Unrelated to this rename.
- Note: `reventless/aws` has no project in the root `jest.config.js`, and the root build's
  clean step wipes `reventless/core`'s test outputs — so neither package's tests run under
  root `pnpm test`. Both were run per-package (with `--experimental-vm-modules`) for this change.

**Not yet deployed.** The rename is a resource replacement; the next alpha deploy will
create the `Platform*` resources and orphan the empty `Admin*` ones.
**Follows:** `docs/guides/terminology-guide.md` and commit `6711ec70a` ("name platform-owned
resources Platform, not Core"), whose argument applies unchanged here: platform substrate should
carry the platform's name. It is also the direct sequel to
`docs/plans/done/retire-stale-core-vocabulary.md` — same shape of drift, different word.

**Motivation:** the framework's built-in plugin answers to three different names at once.

| Prefix | Source | Live AWS resources |
|---|---|---|
| `Platform` | `Platform_Admin_Structure.pluginId` — the model identity, the `reventless:platform` tag value, and the name the terminology guide gives the built-in plugin | — |
| `Plugin*` | `PluginSpec.name` — the Plugin aggregate's own spec name | `PluginAggrEventLog`, `Plugins` |
| `Admin*` | `Platform_Admin.res:123` — `let name = "Admin"` | `AdminDcbEventLog`, `AdminDcbCmdTopic`, `AdminEventColl` |

`Plugin*` is correct — that is an aggregate named after itself, exactly as any plugin's aggregate
would be. `Admin*` is the odd one: it is **platform substrate named neither after the platform nor
after a component**. The terminology guide names the built-in plugin `Platform` and never mentions
"Admin" as a term at all.

**The codebase has already half-made this decision.** `Platform_Admin.res:152` carries the comment:

> *"Admin slice command mutations render `Platform_*` (not `Admin_*`), byte-aligned with the
> hand-declared admin SDL"*

So the **GraphQL surface users actually see already says `Platform_`**. Only the physical
infrastructure still says `Admin`. That is the definition of a leftover: the public name moved, the
resource name did not.

---

## The one thing that makes this different from the Core rename

**"Admin" is not uniformly stale.** Unlike "core", it has a live and *correct* meaning elsewhere:
the Cognito authorization group. 45 grep hits are the authz sense —
`AllowGroups(["Admin"])`, `PluginBaseFragment.res:5` `group: "Admin"`,
`Platform.res:158` `~group="Admin"`, `@aws_auth(cognito_groups: ["Admin"])`, and the
`["Admin", "User"]` test identities.

Those name *an administrator privilege*, not the platform plugin, and they must not move. A blunt
`s/Admin/Platform/` would silently change who is allowed to call admin mutations — a security
change disguised as a rename. **Every tier below is scoped to the construct-name sense only.**

---

## Tier 1 — free (log labels and comments)

No behaviour change, no deployed identity.

| Where | Now | Should be |
|---|---|---|
| `core/src/admin/Admin_Callback.res:15` | `~comp="Admin"` | the platform plugin's name |
| `local/src/Platform.res:1737,1739` | `~comp="Admin"` log labels | same |
| `local/src/Platform.res:878,912` | comments explaining the `"Admin" -> +Dcb -> +CmdTopic` derivation | reword once the name moves |

Prefer binding these to `Platform_Admin_Structure.pluginId` rather than retyping a literal — the
Core rename's best outcome was replacing 7 hardcoded strings with the spec constant, which retires
the drift permanently instead of relocating it.

## Tier 2 — code organisation (module and file names)

**Decided 2026-07-22: in scope, including the `.mjs`.** `Platform_Admin.res` already carries the
`Platform_` prefix; these do not and should follow the chosen target name:

| File | Rename mechanism |
|---|---|
| `core/src/admin/AdminApi.res` | compiler-checked |
| `core/src/admin/Admin_Callback.res` | compiler-checked |
| `aws/src/adapter/Runtime/AdminEventCollectorEntryPoint.mjs` | **NOT compiler-checked — see below** |

Use `git mv` and re-`git add` the edited path so the rename and the content change land together.

### The `.mjs` is the one hazard in this tier

`AdminEventCollectorEntryPoint.mjs` is referenced by a **hardcoded package-path string** for Lambda
bundling — `aws/src/plugin/runtime/PluginRuntime_Builder.res:487`:

```rescript
~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/AdminEventCollectorEntryPoint.mjs"
```

It is a string, not a module reference, so **the compiler cannot catch a mismatch**. Rename the file
without updating the string and the build stays green; it fails at bundle time, or at Lambda cold
start in a deployed environment. This is the same silent-failure class as the Tier 4 dispatch key —
**the file rename and the string must move in lockstep.**

Also update `PluginRuntime_Builder.res.mjs:309`, which carries the same literal in compiled output,
and the nine comment references across `Plugin_Helpers.res`, `PluginConnectExtension_Mapping.res`,
`aws/src/Platform.res`, `PluginRuntime_Builder.res`, `PgChangeFeedRelay_Runtime.res` and
`AppSync_SdlDecorate.res` (harmless, but they are how the next reader finds the file).

Note these entry points are hand-written `.mjs`, not generated — they do not regenerate on build, so
a mistake here persists until someone deploys.

## Tier 3 — published API surface

`Platform_Admin.res:205` — `pluginName: "Admin"` in the MCP schema registration hook.

**Scope analysed 2026-07-22 — narrower than it first looked.** `pluginName` reaches exactly two
places in `MCP_SchemaGenerator.res`:

| Use | Impact |
|---|---|
| Tool **descriptions** — `` `Execute ${fieldName} on ${pluginName}` `` (lines 99, 112) | cosmetic; only surfaces when an entry has no explicit description |
| Resource **URI templates** — `` `${pluginName}/${fieldName}/{id}` `` (lines 142, 152, 177) | **real external contract** — clients address resources as `Admin/plugin/{id}` |

**Tool names do not embed `pluginName`** — tools are named from `fieldName` alone. So this renames
no MCP tool; the churn is limited to clients addressing *resources* by URI.

Separately, the MCP server is already named `` `${serverName}-admin` `` (`MCP_Lambda.res:120`) —
decide whether that follows too.

**Decision: do not do Tier 3 on its own.** Bundle it with Tier 4 so external clients absorb one
break instead of two.

`Platform_Admin.res:80` — `name: "Admin"` on the synthetic `fakePluginDefinition` — is the
`Callback`'s plugin definition, **not** a resource name (see Tier 4). It should still move for
consistency, but nothing infrastructural depends on it.

`PluginBaseFragment.res:5` `group: "Admin"` is **NOT** in this tier — that is the authz group
(non-goal below).

## Tier 4 — deployed identity: the actual drift

`core/src/admin/Platform_Admin.res:123` — `let name = "Admin"`.

**One binding names every platform-owned resource** (grep-verified 2026-07-22 — there is no
shadowing of `name` anywhere between line 123 and line 407):

```
Platform_Admin.res:108   let construct = (...)
              :123         let name = "Admin"
              :150           DcbBuilder.construct(~name, ~childName=name)   → AdminDcbEventLog, AdminDcbCmdTopic, DCB event topic
              :407           EventCollectorHelper.make(~name, ...)          → AdminEventColl
```

So the DCB substrate **and** the EventCollector move together, automatically — there is no way to
rename one without the other, and no separate decision to make about `AdminEventColl`. (An earlier
draft of this plan listed that as an open question; it was based on the wrong assumption that
`AdminEventColl` derived from the `fakePluginDefinition.name` at line 80. It does not.)

It is load-bearing in three ways:

1. **It names a DynamoDB table.** `AdminDcbEventLog` → renaming is a **table replacement**, i.e.
   real data loss. This is strictly more destructive than the Core.Plugin rename, which only cost
   an SQS queue. Also replaces `AdminDcbCmdTopic` (SQS) and the DCB event topic (SNS).
2. **It is a dispatch key.** `DcbEventLog_Operations` stamps every published event's `meta.service`
   with `<name>DcbEventLog`, and `local/src/Platform.res:920,979` compares against the literal
   `"AdminDcbEventLog"`. `meta.service` doubles as the projection dispatch key, and a mismatch
   fails **silently** — no error, just a projection that stops updating. Same failure mode as the
   Core.Plugin dispatch key; **all uses must move in lockstep.** Bind to one constant rather than
   repeating the literal.
3. **It is published** (`reventless-core`).

**Target name is an open question.** `Platform` gives `PlatformDcbEventLog` and matches
`pluginId`; `PlatformAdmin` gives `PlatformAdminDcbEventLog` and keeps the administrative sense
visible. Decide before executing — this is the one choice the whole plan hangs on.

**Timing.** As of 2026-07-22 the alpha `AdminDcbEventLog-faf285c` holds **0 items** (emptied during
the Core.Plugin cutover) and the stack has not yet been redeployed. The table-replacement cost that
normally makes this expensive is currently zero. That window closes on the next deploy that writes
DCB events.

**Precondition before executing:** confirm no stack holds DCB admin state worth keeping, and expect
to wipe + redeploy rather than migrate (standing alpha rule).

---

## Non-goals

- **The Cognito authorization group `"Admin"`.** It names an administrator privilege, not the
  platform plugin. Correct as-is; moving it is a security change, not a rename. This is the single
  most important boundary in this plan.
- **`Platform_Admin_Structure.pluginId`.** Already `"Platform"` — it is the target, not the drift.
- **`Plugin*` resource names** (`PluginAggrEventLog`, `Plugins`). Those derive from the Plugin
  aggregate's own spec name and are correct.
- **Incidental English.** "administrative tools", "the admin API" as prose is ordinary usage.

## Target name — analysed 2026-07-22, recommendation: `Platform`

The plan previously left this open. Analysed below; **recommendation is `Platform`**, not decided.

### What each option produces

| | `Platform` | `PlatformAdmin` |
|---|---|---|
| DynamoDB | `PlatformDcbEventLog` | `PlatformAdminDcbEventLog` |
| SQS | `PlatformDcbCmdTopic`, `PlatformEventColl` | `PlatformAdminDcbCmdTopic`, `PlatformAdminEventColl` |
| `meta.service` | `PlatformDcbEventLog` | `PlatformAdminDcbEventLog` |
| Longest derived name | ~38 chars | ~43 chars |

**Name length is not a constraint** — both are well under the Lambda 64-char / SQS 80-char limits.
Ruled out as a consideration.

### `Platform` is already the established prefix

This is not a greenfield choice. Platform substrate already announces itself as `Platform`
everywhere *except* these resources:

- `Platform_Admin_Structure.pluginId = "Platform"` — the model identity
- GraphQL mutations already render `Platform_*` (comment at `Platform_Admin.res:152`)
- `PlatformApi` — the split-mode AppSync API (`aws/src/Platform.res:1031`)
- `PlatformUIFragments` / `PlatformUIDefinitions` — Lambdas, hardcoded `Platform*` literals

Choosing `Platform` makes these resources join a convention that already exists. Choosing
`PlatformAdmin` leaves them the only platform-owned things with a divergent prefix — structurally
the same defect as today, merely milder: `pluginId=Platform` + resources=`PlatformAdmin*` is still
two names for one thing.

### The one real argument for `PlatformAdmin`, and its limit

A separate plugin **`PlatformInspector`** (lives in the business repo; only comment references in
this repo) emits `PlatformInspector*` resources. Under `Platform`, a `Platform*` glob catches both
the built-in platform and that plugin. `PlatformAdmin*` would select precisely.

**Checked: nothing depends on that prefix.** IAM grants use resolved ARNs/URNs — e.g.
`Resource(platformSqsQueue.urn)` in `HeartbeatRunner_CloudWatchEvents.res` — never name wildcards;
there is no `arn:aws:sqs:...:Platform*` policy in the tree. The ambiguity is therefore **cosmetic**:
it affects reading a console listing, not security, routing, or resolution. The proper
disambiguator already exists and works — the `reventless:platform` tag.

### The question underneath

Does the built-in plugin have an "admin part" distinct from a "non-admin part"? **No.**
`Platform_Admin.construct` takes the extension points, aggregates, read models and all five slice
kinds — it *is* the whole built-in plugin's composition, not a subset. "Admin" describes what the
plugin does, not a region within it. `PlatformAdmin` would preserve a distinction with no referent.

### Where `PlatformAdmin` would win

If the platform is ever expected to own substrate *outside* the admin construct, `Platform*` becomes
a genuine umbrella and a sub-prefix earns its keep. That is a roadmap question the code cannot
answer — settle it before executing.

### Unverified

`PlatformDcbEventLog` has **not** been checked for collisions in the business repo, which is not
visible from here. Grep there before committing to the name — live graph vocabulary lives in those
protocol variants.

## Previously-open questions — all settled 2026-07-22

| Question | Resolution |
|---|---|
| Does `AdminEventColl` move with the DCB resources? | **Dissolved.** Same binding names both (Tier 4) — not a choice. |
| Does Tier 2 (file/module renames) follow? | **Yes, including the `.mjs`.** The un-typechecked path string is the hazard, not a reason to skip. |
| Is Tier 3 (MCP `pluginName`) worth it alone? | **No — bundle with Tier 4.** Affects resource URIs, not tool names. |

The only thing still genuinely open is the **target name** (above): `Platform` recommended, pending
the business-repo collision check.

## Done when

- No identifier under `reventless/*/src` uses "Admin" to mean the platform plugin.
- The authz group `"Admin"` is untouched and still gates the same mutations — verify explicitly,
  ideally with `CommandAuthorizationTest` and `Auth_CognitoTest` green.
- `meta.service` for admin DCB events is derived from one constant, not a repeated literal.
