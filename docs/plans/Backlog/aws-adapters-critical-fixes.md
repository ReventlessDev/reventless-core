# Plan: AWS Adapter Critical Fixes

**Analysis**: [aws-adapters-broad-review.md](../../analysis/aws-adapters-broad-review.md) — table rows #1–#6.

Six critical-severity findings across the AWS adapter surface. Each is either a working bug, a security blocker, or a runtime crash latent in code that ships today. Items are independent and can be tackled in any order, but #2, #3 are tiny enough to land first as cleanup.

## Scope

| # | Finding | File | Class |
|---|---|---|---|
| 1 | MCP JWT signature unverified | [`MCP_Lambda.res`](../../../reventless/reventless-aws/src/adapter/Mcp/MCP_Lambda.res) | Security |
| 2 | `Daily(h, m)` cron expression invalid | [`ScheduledPublisher_CloudWatchEvents_Runtime.res`](../../../reventless/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res) | Correctness |
| 3 | `Array.zip` receipt-handle / parsed-body mispairing | [`CommandTopicChannel_SQS_Runtime.res`](../../../reventless/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res) | Correctness |
| 4 | Cloner runtime `Pulumi.Output.get` (dead code) | [`ClonerRunner_Fargate_Runtime.res`](../../../reventless/reventless-aws/src/adapter/Cloner/ClonerRunner_Fargate_Runtime.res) | Correctness |
| 5 | Scheduler runtime `Pulumi.Output.get` | [`ScheduledPublisher_CloudWatchEvents_Runtime.res`](../../../reventless/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res) | Correctness |
| 6 | `resolvedResource.urn` carries an ARN by convention | [`Util_SQS.res`](../../../reventless/reventless-aws/src/util/Util_SQS.res), Heartbeat + Scheduler | Type-system gap |

## Goals

- All six findings closed in production code.
- Test coverage where mockable (cron, JSON parse pairing, JWT verifier).
- Type-system enforcement (#6) so future drift is compile-time-detected.

## Non-goals

- Re-architecting MCP transport (the Function URL placeholder stands; #1 is just adding signature verification on top).
- Migrating ScheduledPublisher to EventBridge Scheduler (separate long-term plan).

---

## Step 1 — `Daily` cron expression fix (#2)

**File:** [`ScheduledPublisher_CloudWatchEvents_Runtime.res:19`](../../../reventless/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res#L19)

Current:
```rescript
| Daily(hour, minute) => `cron(${minute->Int.toString} ${hour->Int.toString} * * * *)`
```

CloudWatch Events cron requires *exactly one* of day-of-month and day-of-week to be `?`. Using `*` in both fields produces `Cron expressions must have exactly one of D or DOW must be ?`.

Replace with:
```rescript
| Daily(hour, minute) => `cron(${minute->Int.toString} ${hour->Int.toString} * * ? *)`
```

**Tests:** add a unit test asserting `toScheduleExpression(Daily(9, 0)) == "cron(0 9 * * ? *)"`. Apply the same coverage to every other constructor in the function — currently nothing tests this code.

---

## Step 2 — Receipt-handle / body mispairing (#3)

**File:** [`CommandTopicChannel_SQS_Runtime.res:7-21`](../../../reventless/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res#L7-L21)

Current:
```rescript
let jsons = records->Array.filterMap(record => …)        // drops parse failures
let topicItems =
  records->Array.map(record => record.receiptHandle)
  ->Array.zip(jsons)
  ->Array.map(((reference, command)) => { … })
```

If record `N` fails JSON parse, `jsons` is shorter than the receipt-handle list, and `Array.zip` truncates — the *N+1*th handle pairs with the *N*th body, and the trailing handle is silently dropped from the delete batch.

Replace with a single `filterMap` that emits `(receiptHandle, json)` together:

```rescript
let topicItems = records->Array.filterMap(record =>
  switch JSON.parseOrThrow(record.body) {
  | json => Some({ReventlessInfra.CommandTopic.reference: record.receiptHandle, command: json})
  | exception _err =>
    Effect.logError(__MODULE__ ++ ".handleQueueEvent: parse error on " ++ record.receiptHandle)->Effect.runSync
    None
  }
)
```

**Tests:** in `CommandTopicChannel_SQS_RuntimeTest.res`, feed a 3-record batch where record 2 has malformed JSON. Assert that:
- only records 1 and 3 reach `handleJsonCommands`
- the receipt handles attached to those topicItems match the original record 1 and record 3 handles (not 1 and 2)

---

## Step 3 — Delete dead `ClonerRunner_Fargate_Runtime.res` (#4)

**File:** [`ClonerRunner_Fargate_Runtime.res:21-22`](../../../reventless/reventless-aws/src/adapter/Cloner/ClonerRunner_Fargate_Runtime.res#L21-L22)

The file uses `Pulumi.Output.get` at Lambda runtime, which is a deploy-time API — the binding is no longer a Pulumi.Output at runtime. The active deployment uses the inline JS in [`ClonerRunner_Fargate.res:92-113`](../../../reventless/reventless-aws/src/adapter/Cloner/ClonerRunner_Fargate.res#L92-L113); the runtime file is never imported.

Two options:

**Option A (preferred — delete):** remove the file. If/when Cloner moves to ReScript runtime (covered by the Cloner consolidation work, see [aws-adapters-major-fixes.md](aws-adapters-major-fixes.md) §6.6), it will be re-added correctly using env-var-fed config.

**Option B (rewrite):** replace the two `Pulumi.Output.get` calls with `Sys.getEnvUnsafe("TASK_DEFINITION_ARN")` and `Sys.getEnvUnsafe("CLUSTER_ARN")`. Wire the Lambda to pass these as env vars. This is also the pre-condition for actually shipping the ReScript runtime.

Tracker in the major-fixes plan covers Option B as part of the Cloner consolidation work; Option A here is the lower-risk immediate close.

**Tests:** none for Option A. For Option B: integration test that `clone(...)` reads the env vars and forwards them.

---

## Step 4 — Scheduler runtime `Pulumi.Output.get` (#5)

**File:** [`ScheduledPublisher_CloudWatchEvents_Runtime.res:42`](../../../reventless/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res#L42)

Same pattern as #4, but unlike Cloner this code path is **live** — it is invoked when a Scheduler creates CloudWatch Events rules dynamically at command-handling time.

Current:
```rescript
roleArn: role.arn->Pulumi.Output.get
```

The role's ARN is a Pulumi Output at deploy time. At Lambda runtime the captured closure no longer has the value resolvable through `Output.get`.

Approach:

1. At deploy time, when constructing the runtime function, extract the ARN through `Pulumi.Output.apply`:
   ```rescript
   let createSchedule = (role) => role.arn->Pulumi.Output.apply(roleArn =>
     (queueResources, schedule) => { … use roleArn directly … }
   )
   ```
   This binds the ARN into the closure at deploy time.

2. **Or** — pass the ARN through the Lambda environment variable populated at deploy time, and read `Sys.getEnvUnsafe("SCHEDULER_ROLE_ARN")` at runtime. Same pattern as the inline Cloner JS.

Either approach removes the `Pulumi.Output.get` call. Pick the env-var path for symmetry with how every other runtime adapter passes deploy-time-bound config (`Util_DynamoDb_Runtime`, `Util_SQS_Runtime`).

**Tests:** integration test in `ScheduledPublisher_CloudWatchEvents_RuntimeTest.res` (creating one) — mock the AWS SDK PutRule + PutTargets, assert `roleArn` matches the env-var fixture.

---

## Step 5 — `resolvedResource.urn` → typed `Arn.t` (#6)

**Files:**
- [`HeartbeatRunner_CloudWatchEvents.res:55`](../../../reventless/reventless-aws/src/adapter/Heartbeat/HeartbeatRunner_CloudWatchEvents.res#L55)
- [`ScheduledPublisher_CloudWatchEvents.res:43`](../../../reventless/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents.res#L43)
- [`Util_SQS.res`](../../../reventless/reventless-aws/src/util/Util_SQS.res) (`findResolvedResource`)

The field is named `urn` but the value carries an ARN by convention. IAM cannot match a Pulumi URN, so the convention is load-bearing — drift would silently break IAM grants.

Two options:

**Option A — rename `urn` → `arn`:** mechanical change across producers and consumers. Confines the load-bearing field to its actual semantics. Compiler enforces every site updates.

**Option B — phantom-typed wrapper:**
```rescript
module Arn: { type t; let make: string => result<t, string>; let toString: t => string } = {
  type t = string
  let make = s => s->String.startsWith("arn:") ? Ok(s) : Error("not an ARN: " ++ s)
  let toString = s => s
}
```
Use `Arn.t` instead of `string` on the field. Forces every producer to call `Arn.make`, every consumer to call `Arn.toString`.

Option B is type-safer; Option A is a tenth the work and likely sufficient. Recommendation: ship Option A first; revisit Option B if IAM matching breaks again.

**Tests:** none required for the rename — the compiler enforces consistency. For Option B: a unit test that `Arn.make("urn:pulumi:…")` returns `Error`.

---

## Step 6 — MCP JWT signature verification (#1)

**File:** [`MCP_Lambda.res:338-385`](../../../reventless/reventless-aws/src/adapter/Mcp/MCP_Lambda.res#L338-L385)

Current `decodeJwtClaims` is a `%raw` JS that base64url-decodes the payload and returns it. `extractIdentity` reads `sub`, `cognito:username`, `cognito:groups` straight from the unverified payload. With the deploy-time placeholder using a Lambda Function URL with `authType: None`, an attacker forges any identity by base64-encoding a payload.

### Approach

1. Add `aws-jwt-verify` (or implement minimum-viable JWKS verification using `jose`) as a runtime dependency in the layer.
2. At cold start, fetch the Cognito User Pool's JWKS via the configured `USER_POOL_ID` + region. Cache in module scope.
3. Verify each incoming JWT:
   - signature against JWKS (look up `kid`)
   - `iss` matches `https://cognito-idp.<region>.amazonaws.com/<userPoolId>`
   - `aud` (or `client_id`) matches the configured app client
   - `exp` not in the past
   - `token_use` matches expectation (id vs. access)
4. On verification failure, return HTTP 401 from the MCP handler — do not fall through to `extractIdentity`'s base64 decode.
5. On JWKS rotation (verifier surfaces `kid` not found), refetch JWKS once before failing.

### Configuration

Three new env vars, all required:
- `MCP_USER_POOL_ID`
- `MCP_USER_POOL_REGION`
- `MCP_APP_CLIENT_ID`

Wire from the deploy-time placeholder so missing config fails fast at cold start, not at first request.

### Defence in depth

If feasible, also gate the Function URL behind API Gateway with a Cognito User Pool authorizer (no code change in the handler then). The signature verification stays as defence-in-depth in case the Function URL is exposed directly.

### Tests

Unit tests with `aws-jwt-verify`'s test JWKS fixtures:
- Valid token with correct kid/aud/iss → identity extracted.
- Tampered payload → 401.
- Expired token → 401.
- Wrong audience → 401.
- Unknown `kid` after one refetch → 401.

### Rollout

Behind a feature flag (`MCP_REQUIRE_JWT_VERIFICATION=true`) for one release while staging environments verify. Default `true` after one release.

---

## Sequencing

1. **Step 1 (Daily cron)** — half a day, zero risk. Land first.
2. **Step 2 (receipt-handle pairing)** — half a day, well-localised; covered by mock-SQS unit tests.
3. **Step 3 (Cloner runtime delete)** — Option A is one-commit deletion.
4. **Step 5 (urn → arn rename)** — half a day, compiler-enforced; do before #4 since both touch Heartbeat + Scheduler.
5. **Step 4 (Scheduler runtime env-var)** — half a day; integration test required.
6. **Step 6 (MCP JWT verification)** — 2–3 days including JWKS caching and tests.

Total effort: ~5 working days.

## Verification

After each step:
- `pnpm run build 2>&1 | grep -E "Warning|warning|error|Error"` returns clean.
- New tests pass.
- For Step 4, deploy to a staging environment and exercise the schedule path end-to-end.
- For Step 6, smoke test against a real Cognito user pool with known-good and known-bad tokens.

## Out of scope (separate plans)

- All major-severity findings → [aws-adapters-major-fixes.md](aws-adapters-major-fixes.md)
- All minor-severity findings → [aws-adapters-minor-fixes.md](aws-adapters-minor-fixes.md)
