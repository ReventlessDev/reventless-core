// Runtime-pure push engine for the admin ApiSchemaPush SideEffect
// (docs/plans/event-sourced-fragment-registries.md § Reactive writer design).
//
// The ApiFragmentRegistry singleton aggregate's behaviour emits ApiSchemaComputed
// { snapshot } — the WHOLE per-plugin fragment set folded from the aggregate's own
// consistent single-partition state after each change. The ApiSchemaPush SideEffect
// (compiled from ApiSchemaPush.res) subscribes to that event via the aggregate's
// DynamoDB stream (single-shard for a singleton → naturally serialized, no concurrent
// StartSchemaCreation), and hands the snapshot here.
//
// This module stitches one AWS-decorated schema per target API from the snapshot
// (identical decoration to the deploy path via the runtime-pure
// AppSync_SdlDecorate.planAwsPushes), pushes each behind the catastrophic-shrink
// guard, and writes the outcome back with RecordApiFragmentPush onto the
// ApiFragmentRegistry aggregate's command topic so the deploy waiter can poll
// Platform_ApiFragments.
//
// Runtime-purity discipline: NO @pulumi imports (this loads in the SideEffectHandler
// Lambda — see reference_pulumi_leaks_into_lambda_runtime_graph). All config is read
// from env at invocation time; the AppSync push uses the AppSync SDK directly.

import { makeQueueRef, log } from "./HandlerFactoryHelpers.mjs";
import { publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import { planAwsPushes } from "@reventlessdev/reventless-aws/src/components/Api/AppSync_SdlDecorate.res.mjs";
import {
  countRootTypeFields,
  isCatastrophicSchemaShrink,
} from "@reventlessdev/reventless-core/src/components/Api/GraphQL_Stitcher.res.mjs";
import {
  baseFragment as adminBaseFragment,
  systemCallerFieldNames,
} from "@reventlessdev/reventless-core/src/admin/AdminApi.res.mjs";

const COMP = "apiSchemaPush";

// ── AppSync push primitives (mirror AdminEventCollectorEntryPoint.mjs) ──────────

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Push the SDL. Bounded retry on the AppSync API-level lock ("Schema is currently being
// altered" / ConcurrentModification) — the legacy connect-driven mkUpdateApiSchema still
// pushes until Plan Phase 4, and a standalone-service push can also contend. The lock
// clears in seconds, so this is NOT the plan's rejected lagging-read retry (that had no
// ceiling). The singleton aggregate's single-shard stream already serializes THIS writer
// against itself; this only covers cross-writer contention.
async function updateAppSyncSchema(apiId, sdl) {
  const { AppSyncClient, StartSchemaCreationCommand } = await import("@aws-sdk/client-appsync");
  const client = new AppSyncClient({});
  const maxAttempts = 6;
  for (let attempt = 1; ; attempt++) {
    try {
      await client.send(new StartSchemaCreationCommand({ apiId, definition: sdl }));
      return;
    } catch (e) {
      const msg = (e && e.message) || String(e);
      const locked = /being altered|ConcurrentModification|currently in the process/i.test(msg);
      if (!locked || attempt >= maxAttempts) throw e;
      const backoff = Math.min(1000 * 2 ** (attempt - 1), 8000);
      log.warn(`schema push contended (${msg}) — retry ${attempt}/${maxAttempts} in ${backoff}ms`, { comp: COMP });
      await sleep(backoff);
    }
  }
}

// Current live schema as SDL for the shrink guard. "" (not error) when the API has
// no schema yet or introspection fails — the caller treats "" as "no baseline".
async function getCurrentSchemaSdl(apiId) {
  try {
    const { AppSyncClient, GetIntrospectionSchemaCommand } = await import("@aws-sdk/client-appsync");
    const client = new AppSyncClient({});
    const resp = await client.send(new GetIntrospectionSchemaCommand({ apiId, format: "SDL" }));
    if (!resp || !resp.schema) return "";
    return Buffer.from(resp.schema).toString("utf-8");
  } catch (e) {
    log.warn(`could not introspect current schema (${(e && e.message) || e}) — skipping shrink guard`, { comp: COMP });
    return "";
  }
}

function parseShrinkThreshold(raw) {
  const n = raw ? Number(raw) : NaN;
  return Number.isFinite(n) && n > 0 && n < 1 ? n : 0.5;
}

// Emit the SchemaShrinkRejected CloudWatch metric via EMF (raw console.log — must
// stay unwrapped so CloudWatch's EMF auto-detect fires).
function emitShrinkRejectionMetric(apiId, currentRootFields, newRootFields) {
  try {
    // eslint-disable-next-line no-console
    console.log(
      JSON.stringify({
        _aws: {
          Timestamp: Date.now(),
          CloudWatchMetrics: [
            {
              Namespace: "Reventless/Runtime",
              Dimensions: [["ApiId"]],
              Metrics: [{ Name: "SchemaShrinkRejected", Unit: "Count" }],
            },
          ],
        },
        ApiId: apiId,
        SchemaShrinkRejected: 1,
        currentRootFields,
        newRootFields,
      })
    );
  } catch {
    // metric emission is best-effort
  }
}

// ── Config (deploy-derived, injected as Lambda env by the admin SideEffectHandler) ──

function readConfig() {
  const na = (v) => (v && v !== "NOT_AVAILABLE" ? v : "");
  const domainApiId = na(process.env["API_SCHEMA_PUSH_DOMAIN_API_ID"]);
  const platformApiId = na(process.env["API_SCHEMA_PUSH_PLATFORM_API_ID"]) || domainApiId;
  return {
    domainApiId,
    platformApiId,
    splitApi: process.env["API_SCHEMA_PUSH_SPLIT_API"] === "true",
    clonerEnabled: process.env["API_SCHEMA_PUSH_CLONER"] === "true",
    cmdTopicUrl: na(process.env["API_SCHEMA_PUSH_CMD_TOPIC_URL"]),
  };
}

// Write RecordApiFragmentPush back per plugin onto the ApiFragmentRegistry aggregate's
// command topic (FIFO, singleton id="registry"). @noApi + idempotent — a no-op in the
// aggregate behaviour if the plugin was deregistered in the meantime.
async function recordPushOutcomes(cmdTopicUrl, pluginIds, ok, message) {
  if (!cmdTopicUrl || pluginIds.length === 0) return;
  const publisher = sqsPublishJsons(makeQueueRef(cmdTopicUrl), "SQS_FIFO");
  const at = new Date().toISOString();
  const commandJsons = pluginIds.map((pluginId) => ({
    id: "registry",
    meta: { service: "ApiFragmentRegistry", time: at, msgId: "pending", correlationId: pluginId },
    commandJson: { TAG: "RecordApiFragmentPush", pluginId, ok, message, at },
  }));
  try {
    await publisher(commandJsons);
  } catch (e) {
    log.error(`RecordApiFragmentPush dispatch failed: ${(e && e.message) || e}`, { comp: COMP });
  }
}

// ── Entry point ────────────────────────────────────────────────────────────────

// snapshot: array of { pluginId, encoded, protocol, apiTarget } — the consistent
// registry contents after the triggering change, carried on the ApiSchemaComputed event.
export async function pushApiSchema(snapshot) {
  const cfg = readConfig();
  const entries = Array.isArray(snapshot) ? snapshot.filter((e) => e && typeof e.encoded === "string" && e.encoded) : [];
  const pluginIds = [...new Set(entries.map((e) => e.pluginId).filter((p) => typeof p === "string"))];
  if (!cfg.cmdTopicUrl) {
    log.warn("ApiSchemaPush: no command-topic URL configured — skipping", { comp: COMP });
    return;
  }

  // Fragments straight from the consistent snapshot — NO eventually-consistent read.
  const fragments = entries.map((e) => ({
    encoded: e.encoded,
    protocol: typeof e.protocol === "string" ? e.protocol : "graphql",
    target: e.apiTarget === "Platform" ? "Platform" : "Domain",
  }));

  const rawAdminBase = adminBaseFragment(cfg.clonerEnabled);
  const plans = planAwsPushes(rawAdminBase, systemCallerFieldNames, fragments, cfg.splitApi);

  let ok = true;
  let message = "";
  for (const plan of plans) {
    const apiId = plan.api === "PlatformApi" ? cfg.platformApiId : cfg.domainApiId;
    if (!apiId) continue;
    const threshold = parseShrinkThreshold(process.env["RUNTIME_SCHEMA_SHRINK_THRESHOLD"]);
    const currentSdl = await getCurrentSchemaSdl(apiId);
    if (isCatastrophicSchemaShrink(currentSdl, plan.sdl, threshold)) {
      const cur = countRootTypeFields(currentSdl, "Mutation") + countRootTypeFields(currentSdl, "Query");
      const nw = countRootTypeFields(plan.sdl, "Mutation") + countRootTypeFields(plan.sdl, "Query");
      log.error(`ABORTED schema push for ${plan.api} (${apiId}): ${nw} root field(s) vs ${cur} live (threshold ${threshold}).`, { comp: COMP });
      emitShrinkRejectionMetric(apiId, cur, nw);
      ok = false;
      message = `shrink guard aborted push for ${plan.api}`;
      continue;
    }
    try {
      await updateAppSyncSchema(apiId, plan.sdl);
      log.info(`schema push OK: ${plan.api} (${apiId})`, { comp: COMP });
    } catch (e) {
      ok = false;
      message = (e && e.message) || String(e);
      log.error(`schema push FAILED: ${plan.api} (${apiId}): ${message}`, { comp: COMP });
    }
  }

  await recordPushOutcomes(cfg.cmdTopicUrl, pluginIds, ok, message);
}
