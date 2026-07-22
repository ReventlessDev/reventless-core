# Retire the stale "core" vocabulary

**Status:** DONE (2026-07-22) — all four tiers **plus** the optional vestigial-variant removal
landed in one commit. **Decision (2026-07-22):**
Tier 4 was **in scope** — we renamed the built-in extension point `Core.Plugin` → `Platform.Plugin`
rather than enshrining it as a legacy proper noun, because the alpha window made it a plain rename,
not a migration (see Tier 4).

**⚠ Deploy precondition — still outstanding at commit time.** The Tier 4 rename replaces the
`CorePluginExtPointCmdTopic` SQS queue with `PlatformPluginExtPointCmdTopic`. Any alpha stack must
be wiped and redeployed against the new name; connected plugins reconnect only against
`Platform.Plugin`. Nothing was deployed as part of this change.

**Outcome notes:**
- Tier 3's `coreApi` had already been renamed to `platformApi` in source by an earlier change; only
  the published guide was stale, so that bullet reduced to a docs fix.
- `PluginExtensionPoint_Plugin.res` no longer hardcodes the dotted name at all — all 7 uses
  (`~service` dispatch key + 6 `~comp` labels) now read `PluginExtensionPointSpec.name`, which
  removes the silent-failure lockstep hazard described in Tier 4 point 3 permanently.
- Verified: full build clean (the one Warning 27 in `LocalEventLogStorage.res` is pre-existing and
  unrelated); 1349 tests green across interop (50), core (518), local (501), aws (280).
**Owner:** Martin
**Follows:** `docs/guides/terminology-guide.md`, which settled the rule: **Core** names the framework
*code layer* (`reventless-core` / `ReventlessCore`) and never a deployed thing; **Platform** is the
top-level deployment and model unit. The guide records the drift; this plan removes it.

**Motivation:** "core" was used for the platform before the platform term settled, and the leftovers
are still in the tree. They are not a second meaning — they are stale. Left alone they keep teaching
the wrong vocabulary (this is how `ComponentType.Core` came to be used for platform substrate in the
first place, and had to be undone).

The catalogue below is grep-verified. It is deliberately split by **risk**, because the entries look
alike and are not: two of them are internal identifiers, and one is a deployed cross-plugin contract
that also appears in physical resource names.

---

## Tier 1 — free (internal identifiers and comments)

No behaviour change, no deployed identity, compiler-checked. Do these together.

| Where | Now | Should be |
|---|---|---|
| `core/src/util/Util_StackRefs.res` | `coreStackName` (2 uses, same file) | `platformStackName` |
| `core/src/util/Interstack.res` + `Plugin_Builder.res:578` | `coreStackReference` (2 uses) | `platformStackReference` |
| `aws/src/plugin/heartbeat/HeartbeatRunner_CloudWatchEvents.res` | `coreSqsQueue` local + surrounding comments | `platformSqsQueue` |
| `aws/src/plugin/runtime/PluginRuntime_Builder.res` | comment naming `CorePluginExtPointCmdTopic` | keep the resource name, reword the prose |
| `aws/src/Platform.res`, `aws/src/adapter/Mcp/MCP_Lambda.res` | "core API", "core schema", "core administrative tools" | "platform API" / "platform schema" |

Note both stack-reference bindings already read the **`platform`** Pulumi config namespace
(`Pulumi.Config.make(Some("platform"))`) — only the ReScript identifier says "core", so the rename
makes the binding agree with the key it reads.

Rows 3 and 4 (`coreSqsQueue` → `platformSqsQueue`, and the `CorePluginExtPointCmdTopic` comment
reword) sit on the same heartbeat path as the Tier 4 rename, so land them together.

## Tier 2 — deployed string, in-place update

- `HeartbeatRunner_CloudWatchEvents.res` — the EventRule `description`, currently
  *"Send a heartbeat to the Core Plugin ExtensionPoint"* → *"…Platform Plugin ExtensionPoint"*.

A description change updates the rule in place; it is not part of the resource's identity, so there
is no replacement (unlike the queue rename in Tier 4). It shows up as a diff in the next
`pulumi preview`, so land it with the Tier 4 rename rather than as a surprise inside an unrelated
deploy.

## Tier 3 — published API surface

Breaking for consumers, but no infrastructure impact.

- `interop/src/protocol/CompatMatrix.res` — `corePlugin` → `platformPlugin`. Rename this **with**
  Tier 4: both name the same built-in EP. One in-repo consumer (`PluginExtensionPoint_Plugin.res:175`).
  `reventless-interop` is published, but in alpha there are no external callers to protect, so no
  deprecated alias — just rename both.
- Split-mode `coreApi` — appears in `Platform.res` and in the **published** platform-and-plugin
  guide (`GraphQL (core) | 4001`, `Some({coreApi})`). Renaming the field is a doc-and-API change;
  do it with the guide, not before it.

## Tier 4 — deployed identity: rename in scope (alpha window)

`infra/src/types/PluginExtensionPointSpec.res:1` — `let name = "Core.Plugin"` → `"Platform.Plugin"`.

This is the built-in extension point's dotted name, and it is load-bearing in four ways at once:

1. **It feeds physical resource names.** `"Core.Plugin"` is what produces
   `CorePluginExtPointCmdTopic` — the SQS queue the heartbeat Lambda is granted `sqs:SendMessage`
   on. Renaming the spec renames the queue (→ `PlatformPluginExtPointCmdTopic`), which is a
   **replacement**, not an update. The IAM grant follows automatically: the heartbeat runner grants
   on the resolved queue ARN (`coreSqsQueue.urn`), not a hardcoded name.
2. **It is a cross-plugin contract.** Plugins connect to the extension point by name. A rename
   breaks every already-deployed plugin's connection until each is redeployed against the new name.
3. **It is used as a dispatch key.** `PluginExtensionPoint_Plugin.res:108` passes the name to
   `Message.generateMeta`; `meta.service` doubles as the projection dispatch key, and a mismatch
   there fails **silently** (no error, just a projection that stops updating). The same string is
   also the `~comp` log label throughout that file (6 uses). **All uses must move in lockstep** —
   this is the one that fails silently if half-done.
4. **It is published** (`reventless-infra`).

**Why this is a plain rename here, not a migration.** Every cost above (dual-name transition,
redeploy every connected plugin, live queue cutover) is a function of *deployed* state. In alpha with
effectively no platforms deployed, the standing rule is to **wipe the alpha EventLog and redeploy
fresh** rather than write migration code. That collapses the migration to: rename every occurrence at
once → wipe → redeploy. This is the last cheap window; it aligns the last straggler with commit
`6711ec70a` ("name platform-owned resources Platform, not Core"), under which the built-in plugin is
named `Platform` and dotted EP names follow `{Plugin}.{Thing}` — so `Platform.Plugin` is the
*consistent* name and `Core.Plugin` is the stale leftover.

**Precondition before executing:** confirm no alpha stack holds state worth keeping. Any alpha stack
must then be redeployed against the new name — there is no in-place update for the queue rename, and
connected plugins reconnect only against `Platform.Plugin`.

**Grep-verified blast radius** (the full set to move together):
`PluginExtensionPointSpec.res` (source of truth), `PluginExtensionPoint_Plugin.res`
(`~service` dispatch key + 6× `~comp` labels + the `CompatMatrix.corePlugin` consumer),
`CompatMatrix.res` (`corePlugin` binding + comment), `Plugin_Fixtures.res` (test fixture), and
comments in `HeartbeatRunner_CloudWatchEvents.res`, `PluginRuntime_Builder.res`,
`AdminEventCollectorEntryPoint.mjs`. All `.res.mjs` outputs regenerate on build.

## Optional — remove the vestigial variant (DONE — pulled into scope)

`ComponentType.Core` had zero uses (marked vestigial 2026-07-22). Removed: the variant plus its
arms in `toString`, `ofString` and `toName`. Both safety claims were re-verified before removing —
zero construction sites anywhere in `reventless/` or `examples/`, and `ComponentType.ofString`'s
only call sites are `ResourceAttributionTest.res`, which asserts on `"Platform"` and `"Runtime"`,
never `"Core"`. Nothing parses persisted `"Core"`.

No URN impact: the guide's warning about `ComponentType.toString` feeding the Pulumi resource type
token applies to *renaming or re-partitioning* live variants. With zero construction sites, `Core`
never reached a URN, so removing it cannot cause resource replacement.

---

## Non-goals

- **Renaming the `core` package, folder or `ReventlessCore` namespace.** Those are correct: they
  name the code layer, which is exactly what Core means.
- **Touching incidental English.** "typed cold-start core", "the core of the algorithm" and similar
  are ordinary prose, not the framework term.

## Done when

- No identifier or comment under `reventless/*/src` uses "core" to mean the platform. **No
  exceptions** — with Tier 4 in scope, the dotted name becomes `Platform.Plugin`, so there is no
  surviving proper noun to carve out.
- The stack-reference bindings agree with the config namespace they read.
- The drift table in `docs/guides/terminology-guide.md` is emptied as each tier lands.
