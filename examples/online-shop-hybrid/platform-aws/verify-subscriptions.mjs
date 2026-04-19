#!/usr/bin/env node
/**
 * E2E verification for GraphQL subscription Sources A and B.
 *
 * Source B: AddProduct command → DDB write → DDB Stream → StateTopic Lambda
 *           → AppSync Events API → WebSocket subscriber
 *
 * Source A: Not verified here — no SNS-backed plugin event topics exist in the
 *           current example stack. All aggregate event topics use DynamoDB streams
 *           (EventTopicPublisher_DynamoDbStream), which are excluded from
 *           EventLogSubscription wiring by the snsRegistry guard.
 *
 * Usage:
 *   node verify-subscriptions.mjs
 *
 * Prerequisites:
 *   - AWS credentials with appsync:EventPublish + appsync:EventSubscribe + appsync:GraphQL
 *   - Pulumi stack deployed (run from examples/online-shop-hybrid/platform-aws/)
 */

import { createHash, createHmac } from "node:crypto";
import WebSocket from "ws";
import { defaultProvider } from "@aws-sdk/credential-provider-node";

// ─── Config ──────────────────────────────────────────────────────────────────

const REGION = "eu-west-1";
const EVENTS_HTTP_HOST = "djgmm3pprrae7gcfo4oz3intlu.appsync-api.eu-west-1.amazonaws.com";
const EVENTS_REALTIME_HOST = "djgmm3pprrae7gcfo4oz3intlu.appsync-realtime-api.eu-west-1.amazonaws.com";
const DOMAIN_API_ENDPOINT = "https://pixoulfjlzggfcp6vrky3yekd4.appsync-api.eu-west-1.amazonaws.com/graphql";
const DOMAIN_API_ID = "wbbmwqjunzdohdbtuxa6aadvua";

const SOURCE_B_CHANNEL = "/default/catalog_Product";

const TIMEOUT_MS = 30_000;

// ─── SigV4 helpers ───────────────────────────────────────────────────────────

function hmac(key, data) {
  return createHmac("sha256", key).update(data).digest();
}

function sha256hex(data) {
  return createHash("sha256").update(data).digest("hex");
}

function isoDate(d) {
  return d.toISOString().replace(/[:\-]|\.\d{3}/g, "").slice(0, 15) + "Z";
}

function shortDate(d) {
  return d.toISOString().slice(0, 10).replace(/-/g, "");
}

async function sigV4Headers({ method, host, path, body, service, region, credentials }) {
  const now = new Date();
  const amzDate = isoDate(now);
  const dateStamp = shortDate(now);

  const payloadHash = sha256hex(body ?? "");

  const headers = {
    host,
    "x-amz-date": amzDate,
    ...(credentials.sessionToken ? { "x-amz-security-token": credentials.sessionToken } : {}),
  };

  const canonicalHeaders = Object.entries(headers)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([k, v]) => `${k}:${v}\n`)
    .join("");
  const signedHeaders = Object.keys(headers).sort().join(";");

  const canonicalRequest = [
    method,
    path,
    "",
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join("\n");

  const credentialScope = `${dateStamp}/${region}/${service}/aws4_request`;
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    amzDate,
    credentialScope,
    sha256hex(canonicalRequest),
  ].join("\n");

  const kDate = hmac(`AWS4${credentials.secretAccessKey}`, dateStamp);
  const kRegion = hmac(kDate, region);
  const kService = hmac(kRegion, service);
  const kSigning = hmac(kService, "aws4_request");
  const signature = createHmac("sha256", kSigning).update(stringToSign).digest("hex");

  const authorization =
    `AWS4-HMAC-SHA256 Credential=${credentials.accessKeyId}/${credentialScope}, ` +
    `SignedHeaders=${signedHeaders}, Signature=${signature}`;

  return { ...headers, Authorization: authorization };
}

// ─── AppSync Events WebSocket subscription ───────────────────────────────────

async function subscribeToChannel(channel) {
  const creds = await defaultProvider()();

  // Sign the connection init request (POST to /event/realtime with empty body)
  const connHeaders = await sigV4Headers({
    method: "POST",
    host: EVENTS_HTTP_HOST,
    path: "/event/realtime",
    body: "{}",
    service: "appsync",
    region: REGION,
    credentials: creds,
  });

  const headerPayload = JSON.stringify({
    host: EVENTS_HTTP_HOST,
    Authorization: connHeaders.Authorization,
    "x-amz-date": connHeaders["x-amz-date"],
    ...(connHeaders["x-amz-security-token"]
      ? { "x-amz-security-token": connHeaders["x-amz-security-token"] }
      : {}),
  });

  const encodedHeader = Buffer.from(headerPayload).toString("base64");
  const encodedPayload = Buffer.from("{}").toString("base64");

  const wsUrl = `wss://${EVENTS_REALTIME_HOST}/event/realtime`;

  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl, {
      headers: {
        "Sec-WebSocket-Protocol": `header=${encodedHeader}&payload=${encodedPayload}`,
      },
      subprotocols: ["aws-appsync-event-ws"],
    });

    const events = [];
    let subscribed = false;
    const subId = Math.random().toString(36).slice(2);

    const fail = (msg) => {
      ws.close();
      reject(new Error(msg));
    };

    ws.on("open", () => {
      ws.send(JSON.stringify({ type: "connection_init" }));
    });

    ws.on("message", async (raw) => {
      let msg;
      try { msg = JSON.parse(raw.toString()); } catch { return; }

      if (msg.type === "connection_ack") {
        // Sign the subscribe request
        const subHeaders = await sigV4Headers({
          method: "POST",
          host: EVENTS_HTTP_HOST,
          path: `/event/realtime`,
          body: JSON.stringify({ channel }),
          service: "appsync",
          region: REGION,
          credentials: creds,
        });
        ws.send(JSON.stringify({
          type: "subscribe",
          id: subId,
          channel,
          authorization: {
            host: EVENTS_HTTP_HOST,
            Authorization: subHeaders.Authorization,
            "x-amz-date": subHeaders["x-amz-date"],
            ...(subHeaders["x-amz-security-token"]
              ? { "x-amz-security-token": subHeaders["x-amz-security-token"] }
              : {}),
          },
        }));
      } else if (msg.type === "subscribe_success" && msg.id === subId) {
        subscribed = true;
        console.log(`  ✓ Subscribed to ${channel}`);
      } else if (msg.type === "subscribe_error") {
        fail(`Subscribe error: ${JSON.stringify(msg)}`);
      } else if (msg.type === "data" && msg.id === subId) {
        events.push(msg.event ?? msg);
      } else if (msg.type === "connection_error") {
        fail(`Connection error: ${JSON.stringify(msg)}`);
      }
    });

    ws.on("error", reject);

    resolve({
      waitFor: (predicate, timeoutMs) =>
        new Promise((res, rej) => {
          const deadline = Date.now() + timeoutMs;
          const poll = () => {
            const found = events.find(predicate);
            if (found) return res(found);
            if (Date.now() > deadline) return rej(new Error(`Timeout waiting for event on ${channel}`));
            setTimeout(poll, 200);
          };
          poll();
        }),
      close: () => ws.close(),
      isSubscribed: () => subscribed,
    });
  });
}

// ─── GraphQL mutation helper ──────────────────────────────────────────────────

async function callGraphQL(query, variables) {
  const creds = await defaultProvider()();
  const url = new URL(DOMAIN_API_ENDPOINT);
  const body = JSON.stringify({ query, variables });

  const headers = await sigV4Headers({
    method: "POST",
    host: url.hostname,
    path: url.pathname,
    body,
    service: "appsync",
    region: REGION,
    credentials: creds,
  });

  const res = await fetch(DOMAIN_API_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body,
  });

  const json = await res.json();
  if (json.errors?.length) throw new Error(JSON.stringify(json.errors));
  return json.data;
}

// ─── Source B verification ────────────────────────────────────────────────────

async function verifySourceB() {
  console.log("\n── Source B: state-change push (DDB Stream → AppSync Events) ──");

  const productId = `verify-${Date.now()}`;
  const productName = `VerifyProduct-${Date.now()}`;

  console.log(`  Connecting to AppSync Events WebSocket...`);
  const sub = await subscribeToChannel(SOURCE_B_CHANNEL);

  // Wait for subscription to be confirmed before issuing mutation
  await new Promise((res, rej) => {
    const deadline = Date.now() + 5000;
    const poll = () => {
      if (sub.isSubscribed()) return res();
      if (Date.now() > deadline) return rej(new Error("Subscribe handshake timeout"));
      setTimeout(poll, 100);
    };
    poll();
  });

  console.log(`  Sending AddProduct mutation (id=${productId})...`);
  const mutation = `
    mutation AddProduct($id: ID!, $name: String!, $price: Float!, $categoryId: ID!) {
      CatalogPlugin_Product_AddProduct(id: $id, name: $name, price: $price, categoryId: $categoryId)
    }
  `;

  let mutationResult;
  try {
    mutationResult = await callGraphQL(mutation, {
      id: productId,
      name: productName,
      price: 9.99,
      categoryId: "cat-verify",
    });
    console.log(`  Mutation accepted:`, mutationResult);
  } catch (e) {
    sub.close();
    throw new Error(`Mutation failed: ${e.message}`);
  }

  console.log(`  Waiting up to ${TIMEOUT_MS / 1000}s for push event on ${SOURCE_B_CHANNEL}...`);

  try {
    const received = await sub.waitFor(
      (evt) => {
        try {
          const data = typeof evt === "string" ? JSON.parse(evt) : evt;
          return data?.id === productId || JSON.stringify(data).includes(productId);
        } catch { return false; }
      },
      TIMEOUT_MS,
    );
    console.log(`  ✓ Push received:`, JSON.stringify(received).slice(0, 300));
    sub.close();
    return { ok: true, event: received };
  } catch (e) {
    sub.close();
    return { ok: false, error: e.message };
  }
}

// ─── Source A note ────────────────────────────────────────────────────────────

function noteSourceA() {
  console.log("\n── Source A: event-log push (SNS → SQS → Lambda → AppSync Events) ──");
  console.log(
    "  SKIPPED: No SNS-backed plugin event topics in current stack.\n" +
    "  All aggregate event topics use EventTopicPublisher_DynamoDbStream,\n" +
    "  which is excluded from EventLogSubscription wiring by the snsRegistry guard.\n" +
    "  Source A infrastructure is built but has no SNS topics to trigger it."
  );
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log("=== Reventless GraphQL Subscription E2E Verification ===");
  console.log(`  Events API: ${EVENTS_HTTP_HOST}`);
  console.log(`  Domain API: ${DOMAIN_API_ENDPOINT}`);

  let sourceBResult;
  try {
    sourceBResult = await verifySourceB();
  } catch (e) {
    sourceBResult = { ok: false, error: e.message };
    console.error("  ERROR:", e.message);
  }

  noteSourceA();

  console.log("\n=== Results ===");
  console.log("  Source B:", sourceBResult.ok ? "✓ PASS" : `✗ FAIL — ${sourceBResult.error}`);
  console.log("  Source A: ⚠ SKIPPED (no SNS-backed topics deployed)");

  if (!sourceBResult.ok) process.exit(1);
}

main().catch((e) => { console.error(e); process.exit(1); });
