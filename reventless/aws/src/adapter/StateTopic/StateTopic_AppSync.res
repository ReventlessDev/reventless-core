// StateTopic_AppSync.res
// Source B: state-change subscriptions (QueryDb DynamoDB Stream → AppSync Events API).
//
// One shared Lambda per events API handles every stream-enabled QueryDb in the
// platform (admin RMs, user-plugin `ReadModelStream`s, and `StateViewSliceStream`s
// alike). `make` registers an entry in a per-events-API registry; `finish` is
// called once at the end of platform construction and builds the shared
// Lambda + IAM role/policy + per-stream EventSourceMappings from the
// accumulated registry entries.
//
// Channel layout: /default/{topicName}/{pathSegment(entityKey)}
//   topicName    = plugin-prefixed query LIST field name (e.g. "Catalog-Products").
//                  MUST match the AutoUI manifest's queryableDef.queryField,
//                  which the host-shell's AutoLive subscribes on. Using the
//                  singular return type here would orphan the channel.
//   entityKey    = the table's primary-key value(s) extracted from record.Keys.
//                  Single-key tables: just the `id` attribute value.
//                  Composite-key tables: `{id}-{subIdValue}` where subId is the
//                  table's sort-key attribute.
//   pathSegment  = AppSync Events channel segments allow only [A-Za-z0-9-];
//                  every other char (`@`, `.`, `:`, `_`, `/`, …) collapses to
//                  `-`. The DESCRIPTOR BODY carries the ORIGINAL entityKey so
//                  the UI's inPage / selectedRowId comparisons against the
//                  GraphQL row.id still match — only the URL path is sanitised.
//
// Clients subscribe to one of:
//   {topic}/{entityKey}   detail view (one row)
//   {topic}/*             list view  (all rows in the read model)
//
// Prerequisites:
//   - The QueryDb must use QueryDbStorage_DynamoDbStream so its resource has a
//     streamArn (StreamSource resourceInfo).
//
// Usage in the plugin / admin builder (after allQueryDbs are assembled):
//   StateTopic_AppSync.make(
//     ~readModelName="Products",     // QueryDb key = ReadModel Spec.name
//     ~topicName="Catalog_Products", // AppSync Events channel root = list field name
//     ~allQueryDbs,
//     ~eventsApi,
//     ~opts,
//   )
//
// Usage in Platform.res (once, after admin + plugins have wired):
//   StateTopic_AppSync.finish(~eventsApi, ~opts)

open PulumiAws

// ── Registry ──────────────────────────────────────────────────────────────────

type streamEntry = {
  tableName: Pulumi.Output.t<string>,
  streamArn: Pulumi.Output.t<string>,
  topicName: string,
}

// One registry per events API, keyed by `eventsApi.name` (the static Pulumi
// resource name, e.g. "DomainEventsApi"). `make` appends; `finish` drains.
let registry: dict<array<streamEntry>> = Dict.make()

// ── Handler code ─────────────────────────────────────────────────────────────
//
// Processes DynamoDB Stream records → publishes one event per row-change to
// AppSync Events. Channel path: /default/{topicRoot}/{entityKey}.
//
// Topic routing is per-record: `STATE_TOPIC_MAP` is `{ "<ddbTableName>":
// "<topicName>" }`; the handler extracts the table name from
// `record.eventSourceARN` (`…:table/<TableName>/stream/…`) and looks up the
// matching topic. This is what lets a single shared Lambda fan out to every
// stream-enabled RM in the platform.
//
// AppSync Events channel segments allow only [A-Za-z0-9-]. `topicRoot` and the
// channel-path entityKey both run through `pathSegment` (collapses every other
// char to `-`); the descriptor body's `id` keeps the ORIGINAL value so the UI
// can match it against GraphQL row ids.
//
// Payload is a change descriptor (NOT the full row):
//   { changeKind: "Added" | "Updated" | "Removed",
//     id:         <entityKey>,
//     sortKeyValue?: <updatedAt | createdAt if present in the image> }
//
// Uses native Node.js crypto + fetch with SigV4 — no extra SDK packages needed.
// Credentials come from the Lambda execution role via the process.env AWS_* variables.

let handlerCode: string = `
import { createHmac, createHash } from "node:crypto";
import { unmarshall } from "@aws-sdk/util-dynamodb";

const TOPIC_MAP = JSON.parse(process.env.STATE_TOPIC_MAP || "{}");
const APPSYNC_ENDPOINT = process.env.APPSYNC_ENDPOINT; // "https://{eventsApi.dns.http}"
const AWS_REGION = process.env.AWS_REGION ?? "eu-west-1";

function sha256hex(data) {
  return createHash("sha256").update(typeof data === "string" ? data : JSON.stringify(data)).digest("hex");
}
function hmacBuf(key, data) {
  return createHmac("sha256", key).update(data).digest();
}

async function signedHeaders(host, path, body) {
  const accessKeyId = process.env.AWS_ACCESS_KEY_ID;
  const secretAccessKey = process.env.AWS_SECRET_ACCESS_KEY;
  const sessionToken = process.env.AWS_SESSION_TOKEN;
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:\\-]|\\..../g, "").slice(0, 15) + "Z";
  const dateStamp = now.toISOString().slice(0, 10).replace(/-/g, "");
  const headers = { host, "x-amz-date": amzDate, ...(sessionToken ? { "x-amz-security-token": sessionToken } : {}) };
  const canonH = Object.entries(headers).sort(([a],[b]) => a.localeCompare(b)).map(([k,v]) => \`\${k}:\${v}\\n\`).join("");
  const signH = Object.keys(headers).sort().join(";");
  const cr = ["POST", path, "", canonH, signH, sha256hex(body)].join("\\n");
  const scope = \`\${dateStamp}/\${AWS_REGION}/appsync/aws4_request\`;
  const sts = ["AWS4-HMAC-SHA256", amzDate, scope, sha256hex(cr)].join("\\n");
  const kDate = hmacBuf("AWS4" + secretAccessKey, dateStamp);
  const kSigning = hmacBuf(hmacBuf(hmacBuf(kDate, AWS_REGION), "appsync"), "aws4_request");
  const sig = createHmac("sha256", kSigning).update(sts).digest("hex");
  return { ...headers, Authorization: \`AWS4-HMAC-SHA256 Credential=\${accessKeyId}/\${scope}, SignedHeaders=\${signH}, Signature=\${sig}\` };
}

// AppSync Events channel segments allow only [A-Za-z0-9-]. Anything else
// (\`@\`, \`.\`, \`:\`, \`_\`, \`/\`, …) collapses to \`-\` so the segment is a
// legal channel-path token. The UI's AutoLive.normalizeSegment uses the same
// rule for Entity-scoped subscribes.
function pathSegment(value) {
  return String(value).replace(/[^A-Za-z0-9-]/g, "-");
}

// Map record.eventSourceARN → topicRoot via STATE_TOPIC_MAP.
// Stream ARNs look like: arn:aws:dynamodb:<region>:<acct>:table/<TableName>/stream/<ts>
function topicRootFromEventSourceArn(arn) {
  const m = arn && arn.match(/:table\\/([^/]+)\\/stream\\//);
  if (!m) return undefined;
  const topicName = TOPIC_MAP[m[1]];
  if (topicName === undefined) return undefined;
  return pathSegment(topicName);
}

// Build entityKey from record.dynamodb.Keys. Framework convention:
// partition-key attr is named "id"; composite tables have one extra attr (the
// sort key) whose name comes from the projection's subIdConfig.subIdField.
// Returns the ORIGINAL key string — the descriptor body uses this verbatim so
// AutoListView can match it against the GraphQL row.id. The channel path
// segment is derived later via pathSegment().
function entityKeyFromRecord(record) {
  const keys = unmarshall(record.dynamodb.Keys ?? {});
  const id = keys.id;
  if (id === undefined) {
    // Defensive: framework always names the partition key "id". If a future
    // table breaks the convention, fall back to a stable sort-join.
    const names = Object.keys(keys).sort();
    return names.map((n) => String(keys[n])).join("-");
  }
  const subIdName = Object.keys(keys).find((k) => k !== "id");
  return subIdName === undefined
    ? String(id)
    : String(id) + "-" + String(keys[subIdName]);
}

// Map DDB stream eventName → descriptor changeKind.
function changeKindFor(eventName) {
  switch (eventName) {
    case "INSERT": return "Added";
    case "MODIFY": return "Updated";
    case "REMOVE": return "Removed";
    default:       return "Updated";  // defensive default — shouldn't fire
  }
}

// Pick the "natural" sort timestamp from an unmarshalled image. Conventions
// in this codebase prefer updatedAt; createdAt is the fallback for views that
// never mutate after insert. Returns undefined if neither is present.
function pickSortKeyValue(image) {
  if (image && typeof image.updatedAt === "string") return image.updatedAt;
  if (image && typeof image.createdAt === "string") return image.createdAt;
  return undefined;
}

export async function handler(event) {
  const url = new URL(APPSYNC_ENDPOINT);
  let transientErr;
  for (const record of event.Records) {
    const topicRoot = topicRootFromEventSourceArn(record.eventSourceARN);
    if (topicRoot === undefined) {
      console.warn("StateTopic: unknown table for ARN", record.eventSourceARN);
      continue;
    }
    const channelRoot = "/default/" + topicRoot;
    const image =
      record.eventName === "REMOVE"
        ? record.dynamodb.OldImage
        : record.dynamodb.NewImage;
    if (image === undefined) continue;
    const entityKey = entityKeyFromRecord(record);
    const channel = channelRoot + "/" + pathSegment(entityKey);
    const unmarshalled = unmarshall(image);
    const descriptor = {
      changeKind: changeKindFor(record.eventName),
      id: entityKey,
    };
    const sortKeyValue = pickSortKeyValue(unmarshalled);
    if (sortKeyValue !== undefined) descriptor.sortKeyValue = sortKeyValue;
    const body = JSON.stringify({ id: record.eventID, channel, events: [JSON.stringify(descriptor)] });
    const auth = await signedHeaders(url.hostname, "/event", body);
    try {
      const res = await fetch(APPSYNC_ENDPOINT + "/event", {
        method: "POST",
        headers: { accept: "application/json, text/javascript", "content-encoding": "amz-1.0", "content-type": "application/json; charset=UTF-8", ...auth },
        body,
      });
      if (!res.ok) {
        const txt = await res.text();
        // 4xx: permanent (bad request, auth, channel format) — retrying won't
        // help. Log structurally so a CloudWatch metric filter on
        // "STATE_TOPIC_PUBLISH_FAILED type=permanent" surfaces it; continue
        // processing so one bad record doesn't block the rest of the batch.
        // 5xx / network: transient — record it and throw at the end so the
        // ESM retries (bounded by maximumRetryAttempts + bisectBatch).
        const isTransient = res.status >= 500;
        const tag = isTransient ? "transient" : "permanent";
        console.error(
          "STATE_TOPIC_PUBLISH_FAILED type=" + tag +
          " status=" + res.status +
          " channel=" + channel +
          " body=" + txt.slice(0, 500)
        );
        if (isTransient) transientErr = new Error("StateTopic publish failed: " + res.status);
      }
    } catch (e) {
      // Network-level error (DNS, connection refused, timeout) — always transient.
      console.error(
        "STATE_TOPIC_PUBLISH_FAILED type=transient status=network" +
        " channel=" + channel +
        " err=" + (e && e.message)
      );
      transientErr = e;
    }
  }
  // Throw after the loop so a single transient error doesn't stop us from
  // emitting other records' descriptors first. The ESM will retry the batch;
  // bisectBatchOnFunctionError isolates the bad record across retries.
  if (transientErr) throw transientErr;
}
`

// ── Registration ──────────────────────────────────────────────────────────────

let make = (
  ~readModelName: string,
  ~topicName: string,
  ~allQueryDbs: ReventlessCore.QueryDb.allOutputs,
  ~eventsApi: AppSync_EventsApi.t,
  ~opts as _: Pulumi.CustomResourceOptions.t,
) => {
  // Look up the QueryDb resources by ReadModel Spec.name, then find the
  // DynamoDB stream resource within them. Requires QueryDbStorage_DynamoDbStream.
  let streamResource =
    allQueryDbs
    ->ReventlessCore.Util.ReadModel.queryDbStorageResources(readModelName)
    ->Util_DynamoDbStream.findResource

  let streamArn = Util_DynamoDbStream.streamArnFromDynamoDbTableResource(streamResource)
  let tableName = streamResource.name

  let key = eventsApi.name
  let entries = registry->Dict.get(key)->Option.getOr([])
  registry->Dict.set(key, entries->Array.concat([{tableName, streamArn, topicName}]))
}

// ── Finalize: build the shared Lambda + IAM + ESMs ────────────────────────────

let finish = (
  ~eventsApi: AppSync_EventsApi.t,
  ~opts: Pulumi.CustomResourceOptions.t,
) => {
  let key = eventsApi.name
  switch registry->Dict.get(key) {
  | None => ()
  | Some([]) => ()
  | Some(entries) =>
    let name = eventsApi.name

    // IAM role for the shared Lambda (Lambda service principal).
    let lambdaRole = IAM.Role.makeWithDefaultPolicy(
      ~name=name ++ "StateTopicRole",
      ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
      ~tags=AWS.Tags.make(
        ~name=name ++ "StateTopicRole",
        ~kind=ReventlessCore.QueryDb.componentType,
        ~role=Identity,
        ~component=name,
      ),
      ~opts,
    )

    // IAM policy: read from every stream + publish to the events API.
    let streamArnsOutput =
      entries->Array.map(e => e.streamArn)->Pulumi.Output.all
    let _ =
      (streamArnsOutput, eventsApi.api.apiArn)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((streamArns, apiArn)) => {
        open PolicyDocument
        let _rolePolicy = IAM.RolePolicy.make(
          ~name=name ++ "StateTopicPolicy",
          ~args={
            IAM.RolePolicy.policy: PolicyDocument.make(
              ~id=name ++ "StateTopicPolicy",
              ~statements=[
                {
                  sid: "AllowLambdaLogging",
                  effect: Allow,
                  actions: Action("logs:*"),
                  resources: Resource("arn:aws:logs:*:*:*"),
                },
                {
                  sid: "AllowReadDynamoDbStream",
                  effect: Allow,
                  actions: Actions([
                    "dynamodb:DescribeStream",
                    "dynamodb:GetRecords",
                    "dynamodb:GetShardIterator",
                    "dynamodb:ListStreams",
                  ]),
                  resources: Resources(streamArns),
                },
                {
                  sid: "AllowPublishAppSyncEvents",
                  effect: Allow,
                  actions: Action("appsync:EventPublish"),
                  resources: Resource(apiArn ++ "/*"),
                },
              ],
            )
            ->PolicyDocument.toJsonString
            ->Pulumi.Input.make,
            role: lambdaRole.id->Pulumi.Output.asInput,
          },
          ~opts,
        )
      })

    // STATE_TOPIC_MAP env var — `{ <tableName>: <topicName> }` JSON object.
    // `topicName` is already a resolved string at deploy time; `tableName`
    // is an Output, so we await all of them and build the JSON inside apply.
    let topicMapJson =
      entries
      ->Array.map(e => e.tableName)
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(tableNames => {
        let dict = Dict.make()
        tableNames->Array.forEachWithIndex((tableName, i) => {
          let topicName = (entries->Array.getUnsafe(i)).topicName
          dict->Dict.set(tableName, topicName->JSON.Encode.string)
        })
        dict->JSON.Encode.object->JSON.stringify
      })

    // Shared Lambda — handler code is identical for every stream-enabled RM;
    // routing is per-record via STATE_TOPIC_MAP env var.
    let archiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
    archiveContents->Dict.set(
      "index.mjs",
      Pulumi.Asset.stringAsset(handlerCode)->Pulumi.Archive.assetToAssetOrArchive,
    )
    // ESM self-containment: the handler imports @aws-sdk/util-dynamodb, provided
    // by the nodejs22.x runtime only under /var/runtime — unreachable from
    // /var/task ESM without the resolver hook. Ship the loader + set its env vars.
    let loaderHash = Util_Bundle.addEsmLoaderAssets(archiveContents)
    let code = Pulumi.Archive.assetArchive(archiveContents)
    let sourceCodeHash = Util_Bundle.hashString(handlerCode ++ "\n---\n" ++ loaderHash)

    let layers =
      Lambda.reventlessLayerArn
      ->Option.map(arn => [arn->Pulumi.Input.make])
      ->Option.getOr([])
      ->Pulumi.Input.make

    let appsyncEndpoint = AppSync_EventsApi.httpEndpoint(eventsApi)

    let lambda = Lambda.Function.make(
      ~name=name ++ "StateTopicPublisher",
      ~args={
        handler: "index.handler"->Pulumi.Input.make,
        runtime: "nodejs22.x"->Pulumi.Input.make,
        code: code->Pulumi.Input.make,
        sourceCodeHash: sourceCodeHash->Pulumi.Input.make,
        role: lambdaRole.arn->Pulumi.Output.asInput,
        memorySize: 256->Pulumi.Input.make,
        timeout: 30->Pulumi.Input.make,
        layers,
        tags: AWS.Tags.make(~name=name ++ "StateTopic", ~kind=ReventlessCore.QueryDb.componentType, ~role=StateTopic, ~component=name),
        environment: (
          {
            Lambda.Function.variables: Dict.fromArray([
              ("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make),
              ("APPSYNC_ENDPOINT", appsyncEndpoint->Pulumi.Output.asInput),
              ("STATE_TOPIC_MAP", topicMapJson->Pulumi.Output.asInput),
              ("NODE_OPTIONS", Util_Bundle.esmLoaderNodeOptions->Pulumi.Input.make),
              ("ESM_FALLBACK_DIRS", Util_Bundle.esmFallbackDirs->Pulumi.Input.make),
            ]),
          }: Lambda.Function.functionEnvironment
        )->Pulumi.Input.make,
      },
      ~opts,
    )

    // One EventSourceMapping per stream, all targeting the shared Lambda.
    // Retry posture: the handler throws on 5xx / network errors and logs-and-
    // continues on 4xx. `maximumRetryAttempts: 3` bounds the per-record
    // retries so a permanently broken record (default DDB stream behaviour is
    // -1 → forever, which would wedge the shard); `bisectBatchOnFunctionError`
    // isolates the bad record across those retries instead of redelivering
    // the whole batch each time.
    entries->Array.forEach(entry => {
      let esmName = entry.topicName ++ "Stream2" ++ name ++ "StateTopic"
      let _esm = EventSourceMapping.make(
        ~name=esmName,
        ~args={
          EventSourceMapping.functionName: lambda.arn->Pulumi.Output.asInput,
          eventSourceArn: entry.streamArn->Pulumi.Output.asInput,
          startingPosition: LATEST,
          maximumRetryAttempts: 3,
          bisectBatchOnFunctionError: true,
          tags: AWS.Tags.make(
            ~name=esmName,
            ~kind=ReventlessCore.QueryDb.componentType,
            ~role=EventSourceMapping,
            ~component=name,
          ),
        },
        ~opts=Some(opts),
      )
    })

    // Clear the registry so a second platform construction in the same process
    // (tests, dev hot reload) starts fresh.
    registry->Dict.set(key, [])
  }
}
