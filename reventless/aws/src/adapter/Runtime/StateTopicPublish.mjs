// StateTopicPublish.mjs
// B3.3: Postgres live-update publisher — the projection-Lambda-side counterpart
// of the DynamoDB StateTopic Lambda (StateTopic_AppSync.res).
//
// On the DynamoDB path a shared Lambda reads the table's stream and POSTs a
// change descriptor to the AppSync Events API. Postgres read models have no
// stream, so (design (a), mirroring the reventless-local Sqlite/InMemory
// backends) the projection Lambda publishes the SAME descriptor itself, right
// after it writes the `qdb_<name>` row. The wire contract — channel layout,
// descriptor shape, SigV4 signing — is byte-identical to StateTopic_AppSync so
// the browser/AutoLive side cannot tell the two backends apart.
//
// Channel:  /default/{pathSegment(topicName)}/{pathSegment(entityKey)}
// Descriptor: { changeKind: "Updated" | "Removed", id: <entityKey>,
//               sortKeyValue?: <updatedAt | createdAt if present> }
//
// changeKind is fixed per operation (save→"Updated", delete→"Removed"): a
// Postgres upsert doesn't distinguish insert vs update, and the Sqlite/InMemory
// backends already collapse save→"Updated" (LocalBus.res:213) — the UI treats a
// first-seen "Updated" row as an insert, so no Added detection is needed.
//
// Publish failures are LOGGED AND SWALLOWED: the projection row is already
// committed when this runs, and the projection Lambda is at-least-once — throwing
// would re-run the projection and duplicate work. A dropped live notification
// only means the UI refreshes the list on its next load, not data loss.
//
// Uses native Node.js crypto + fetch with SigV4; credentials come from the
// Lambda execution role via the process.env AWS_* variables.

import { createHmac, createHash } from "node:crypto";

function sha256hex(data) {
  return createHash("sha256").update(typeof data === "string" ? data : JSON.stringify(data)).digest("hex");
}
function hmacBuf(key, data) {
  return createHmac("sha256", key).update(data).digest();
}

async function signedHeaders(host, path, body, region) {
  const accessKeyId = process.env.AWS_ACCESS_KEY_ID;
  const secretAccessKey = process.env.AWS_SECRET_ACCESS_KEY;
  const sessionToken = process.env.AWS_SESSION_TOKEN;
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:\-]|\..../g, "").slice(0, 15) + "Z";
  const dateStamp = now.toISOString().slice(0, 10).replace(/-/g, "");
  const headers = { host, "x-amz-date": amzDate, ...(sessionToken ? { "x-amz-security-token": sessionToken } : {}) };
  const canonH = Object.entries(headers).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => `${k}:${v}\n`).join("");
  const signH = Object.keys(headers).sort().join(";");
  const cr = ["POST", path, "", canonH, signH, sha256hex(body)].join("\n");
  const scope = `${dateStamp}/${region}/appsync/aws4_request`;
  const sts = ["AWS4-HMAC-SHA256", amzDate, scope, sha256hex(cr)].join("\n");
  const kDate = hmacBuf("AWS4" + secretAccessKey, dateStamp);
  const kSigning = hmacBuf(hmacBuf(hmacBuf(kDate, region), "appsync"), "aws4_request");
  const sig = createHmac("sha256", kSigning).update(sts).digest("hex");
  return { ...headers, Authorization: `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${scope}, SignedHeaders=${signH}, Signature=${sig}` };
}

// AppSync Events channel segments allow only [A-Za-z0-9-]; anything else
// collapses to `-`. The descriptor body keeps the ORIGINAL entityKey so the UI
// can match it against GraphQL row ids. Same rule as StateTopic_AppSync and the
// UI's AutoLive.normalizeSegment.
function pathSegment(value) {
  return String(value).replace(/[^A-Za-z0-9-]/g, "-");
}

// Pick the natural sort timestamp from the saved state (updatedAt preferred,
// createdAt fallback). Mirrors StateTopic_AppSync.pickSortKeyValue and
// LocalBus.pickSortKeyValue.
function pickSortKeyValue(state) {
  if (state && typeof state === "object" && !Array.isArray(state)) {
    if (typeof state.updatedAt === "string") return state.updatedAt;
    if (typeof state.createdAt === "string") return state.createdAt;
  }
  return undefined;
}

// Build the descriptor + channel and POST to {endpoint}/event.
// - endpoint:   base AppSync Events HTTP endpoint (no trailing /event).
// - region:     AWS region for the SigV4 credential scope.
// - topicName:  the plugin-prefixed query LIST field name (channel root).
// - entityKey:  ORIGINAL entity key (id or `id-subKey`) — descriptor body + path.
// - changeKind: "Updated" (save) | "Removed" (delete).
// - sortKeyValue: optional; included when defined.
// - dedupeId:   AppSync publish `id` (idempotency hint).
export async function publishStateChange({ endpoint, region, topicName, entityKey, changeKind, sortKeyValue, dedupeId }) {
  if (!endpoint || !topicName) return; // not live-enabled — no-op
  try {
    const url = new URL(endpoint);
    const channel = "/default/" + pathSegment(topicName) + "/" + pathSegment(entityKey);
    const descriptor = { changeKind, id: entityKey };
    if (sortKeyValue !== undefined) descriptor.sortKeyValue = sortKeyValue;
    const body = JSON.stringify({
      id: dedupeId || (topicName + ":" + entityKey + ":" + changeKind),
      channel,
      events: [JSON.stringify(descriptor)],
    });
    const auth = await signedHeaders(url.hostname, "/event", body, region || process.env.AWS_REGION || "eu-west-1");
    const res = await fetch(endpoint + "/event", {
      method: "POST",
      headers: {
        accept: "application/json, text/javascript",
        "content-encoding": "amz-1.0",
        "content-type": "application/json; charset=UTF-8",
        ...auth,
      },
      body,
    });
    if (!res.ok) {
      const txt = await res.text();
      // Swallow (see module docstring): the row is already committed. Log
      // structurally so a CloudWatch metric filter on
      // "PG_STATE_TOPIC_PUBLISH_FAILED" can surface persistent breakage.
      console.error(
        "PG_STATE_TOPIC_PUBLISH_FAILED status=" + res.status +
        " channel=" + channel +
        " body=" + txt.slice(0, 500)
      );
    }
  } catch (e) {
    console.error("PG_STATE_TOPIC_PUBLISH_FAILED status=network err=" + (e && e.message));
  }
}

// Compose the entity key from a save/delete's id + optional sub-key. Matches
// StateTopic_AppSync.entityKeyFromRecord and QueryDbStorage_Sqlite.entityKeyFor:
// single-key tables → id; composite tables → `id-subKeyValue`.
export function entityKeyFor(id, state, subIdField) {
  if (subIdField === undefined || subIdField === null) return String(id);
  const subValue =
    state && typeof state === "object" && !Array.isArray(state) ? state[subIdField] : undefined;
  return subValue === undefined || subValue === null
    ? String(id)
    : String(id) + "-" + String(subValue);
}

// Wrap a Postgres QueryDb operation set so every save/delete also publishes a
// live-update descriptor. `liveConfig` = { endpoint, region, topicName,
// subIdField }. When endpoint/topicName are absent the ops pass through
// unchanged (non-stream / non-live read models pay nothing).
//
// Note on batch ops: saveBatch/deleteBatch fan out one publish per item, after
// the batch write resolves — the row set is committed as a unit, and each row
// gets its own descriptor exactly as N single writes would.
export function withLiveUpdates(ops, liveConfig) {
  const { endpoint, topicName, region, subIdField } = liveConfig || {};
  if (!endpoint || !topicName) return ops;
  // `publish` is injectable for headless testing (default = the real SigV4
  // publisher); tests pass a capturing stub so the wrapping logic can be
  // asserted without fetch/crypto.
  const publish = (liveConfig && liveConfig.publish) || publishStateChange;

  const publishSaved = async (id, state) =>
    publish({
      endpoint, region, topicName,
      entityKey: entityKeyFor(id, state, subIdField),
      changeKind: "Updated",
      sortKeyValue: pickSortKeyValue(state),
    });

  const publishRemovedKey = async (entityKey) =>
    publish({ endpoint, region, topicName, entityKey, changeKind: "Removed" });

  // Resolve the entity keys a delete will remove — computed BEFORE the delete so
  // a partition-wide delete on a composite table can still enumerate its rows
  // (mirrors QueryDbStorage_Sqlite.delete's rowKeysForPartition). `subIdOpt` is
  // the adapter's `option<(field, subValue)>`: undefined (partition-wide) or a
  // `[field, subValue]` array (one specific row).
  const removedKeysFor = async (id, subIdOpt) => {
    if (subIdOpt) return [String(id) + "-" + String(subIdOpt[1])];
    if (subIdField === undefined || subIdField === null) return [String(id)];
    // Composite table, whole-partition delete (`Delete(id)` / `DeleteMany`):
    // read the live rows so each removed sub-row gets its own descriptor,
    // exactly as N DynamoDB stream REMOVE records would.
    const res = await ops.load(id);
    const rows = res && res.TAG === "Ok" ? res._0 : [];
    return rows.map((row) => entityKeyFor(id, row, subIdField));
  };

  return {
    ...ops,
    save: async (id, state, saveMode, ttl) => {
      const r = await ops.save(id, state, saveMode, ttl);
      await publishSaved(id, state);
      return r;
    },
    saveBatch: async (items) => {
      const r = await ops.saveBatch(items);
      await Promise.all(items.map(([id, state]) => publishSaved(id, state)));
      return r;
    },
    delete: async (id, subIdOpt) => {
      const keys = await removedKeysFor(id, subIdOpt);
      const r = await ops.delete(id, subIdOpt);
      await Promise.all(keys.map(publishRemovedKey));
      return r;
    },
    deleteBatch: async (entries) => {
      const keyGroups = await Promise.all(entries.map(([id, subIdOpt]) => removedKeysFor(id, subIdOpt)));
      const r = await ops.deleteBatch(entries);
      await Promise.all(keyGroups.flat().map(publishRemovedKey));
      return r;
    },
  };
}
