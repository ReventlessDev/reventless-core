// StateTopic_AppSync.res
// Source B: state-change subscriptions (QueryDb DynamoDB Stream → AppSync Events API).
//
// Creates deploy-time resources for one ReadModel or StateViewSlice:
//   QueryDb DynamoDB table (stream-enabled) → Lambda → AppSync Events channel
//
// Channel layout: /default/{topicName}/{entityKey}  (underscores → hyphens)
//   topicName    = plugin-prefixed query return type (e.g. "catalog-Product")
//   entityKey    = the table's primary-key value(s) extracted from record.Keys.
//                  Single-key tables: just the `id` attribute value.
//                  Composite-key tables: `{id}-{subIdValue}` where subId is the
//                  table's sort-key attribute.
//
// Clients subscribe to one of:
//   {topic}/{entityKey}   detail view (one row)
//   {topic}/*             list view  (all rows in the read model)
//
// Prerequisites:
//   - The QueryDb must use QueryDbStorage_DynamoDbStream so its resource has a
//     streamArn (StreamSource resourceInfo).
//
// Usage in the plugin builder (after allQueryDbs are assembled):
//   StateTopic_AppSync.make(
//     ~readModelName="Product",      // QueryDb key = ReadModel Spec.name
//     ~topicName="catalog_Product",  // AppSync Events channel root segment
//     ~allQueryDbs,
//     ~eventsApi,
//     ~opts,
//   )

open PulumiAws

// ── Handler code ─────────────────────────────────────────────────────────────
//
// Processes DynamoDB Stream records → publishes one event per row-change to
// AppSync Events. Channel path: /default/{topicRoot}/{entityKey}.
//
// AppSync Events channels disallow underscores in segments — `topicRoot` and
// `entityKey` are both normalised with `_` → `-`.
//
// `entityKey` is derived from `record.dynamodb.Keys` (the row's primary-key
// attributes, always present on INSERT / MODIFY / REMOVE). The framework
// names the partition-key attribute "id" by convention
// (QueryDbStorage_DynamoDb); composite-key tables also have a sort-key attr
// whose name comes from the read model's subIdConfig.subIdField.
//
// Payload (for Phase 1) remains the full row state — `NewImage` for INSERT /
// MODIFY, `OldImage` for REMOVE. The change-descriptor reshape is Phase 2.
//
// Uses native Node.js crypto + fetch with SigV4 — no extra SDK packages needed.
// Credentials come from the Lambda execution role via the process.env AWS_* variables.

let makeHandlerCode = (~topicName: string): string => {
  // AppSync Events channels cannot contain underscores — replace with hyphens.
  let topicRoot = topicName->String.replaceAll("_", "-")
  `
import { createHmac, createHash } from "node:crypto";
import { unmarshall } from "@aws-sdk/util-dynamodb";

const TOPIC_ROOT = "/default/${topicRoot}";
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

// AppSync Events channel segments allow [A-Za-z0-9-]; values may carry "_"
// or other separators. Underscores are normalised to "-" so the URL-encoded
// segment never breaks the channel grammar.
function segment(value) {
  return String(value).replaceAll("_", "-");
}

// Build entityKey from record.dynamodb.Keys. Framework convention:
// partition-key attr is named "id"; composite tables have one extra attr (the
// sort key) whose name comes from the projection's subIdConfig.subIdField.
function entityKeyFromRecord(record) {
  const keys = unmarshall(record.dynamodb.Keys ?? {});
  const id = keys.id;
  if (id === undefined) {
    // Defensive: framework always names the partition key "id". If a future
    // table breaks the convention, fall back to a stable sort-join.
    const names = Object.keys(keys).sort();
    return names.map((n) => segment(keys[n])).join("-");
  }
  const subIdName = Object.keys(keys).find((k) => k !== "id");
  return subIdName === undefined
    ? segment(id)
    : segment(id) + "-" + segment(keys[subIdName]);
}

export async function handler(event) {
  const url = new URL(APPSYNC_ENDPOINT);
  for (const record of event.Records) {
    const image =
      record.eventName === "REMOVE"
        ? record.dynamodb.OldImage
        : record.dynamodb.NewImage;
    if (image === undefined) continue;
    const entityKey = entityKeyFromRecord(record);
    const channel = TOPIC_ROOT + "/" + entityKey;
    const payload = unmarshall(image);
    const body = JSON.stringify({ id: record.eventID, channel, events: [JSON.stringify(payload)] });
    const auth = await signedHeaders(url.hostname, "/event", body);
    const res = await fetch(APPSYNC_ENDPOINT + "/event", {
      method: "POST",
      headers: { accept: "application/json, text/javascript", "content-encoding": "amz-1.0", "content-type": "application/json; charset=UTF-8", ...auth },
      body,
    });
    if (!res.ok) {
      const txt = await res.text();
      console.error("StateTopic publish failed:", res.status, txt);
    }
  }
}
`
}

// ── Deploy-time resource builder ──────────────────────────────────────────────

let make = (
  ~readModelName: string,
  ~topicName: string,
  ~allQueryDbs: ReventlessCore.QueryDb.allOutputs,
  ~eventsApi: AppSync_EventsApi.t,
  ~opts: Pulumi.CustomResourceOptions.t,
) => {
  // Look up the QueryDb resources by ReadModel Spec.name, then find the
  // DynamoDB stream resource within them. Requires QueryDbStorage_DynamoDbStream.
  let name = readModelName
  let streamResource =
    allQueryDbs
    ->ReventlessCore.Util.ReadModel.queryDbStorageResources(readModelName)
    ->Util_DynamoDbStream.findResource

  // Extract the stream ARN from resourceInfo (urn holds the table ARN; stream ARN is in StreamSource).
  let streamArn = Util_DynamoDbStream.streamArnFromDynamoDbTableResource(streamResource)

  // IAM role for the Lambda (Lambda service principal)
  let lambdaRole = IAM.Role.makeWithDefaultPolicy(
    ~name=name ++ "StateTopicRole",
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
    ~opts,
  )

  // IAM policy: read DynamoDB stream + publish to AppSync Events API
  let _ =
    (
      streamArn,
      eventsApi.api.apiArn,
    )
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((streamArn, apiArn)) => {
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
                resources: Resource(streamArn),
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

  // Lambda function — processes DynamoDB Stream records and publishes to AppSync Events
  let handlerCode = makeHandlerCode(~topicName)
  let archiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
  archiveContents->Dict.set(
    "index.mjs",
    Pulumi.Asset.stringAsset(handlerCode)->Pulumi.Archive.assetToAssetOrArchive,
  )
  let code = Pulumi.Archive.assetArchive(archiveContents)
  let sourceCodeHash = Util_Bundle.hashString(handlerCode)

  let layers =
    Lambda.reventlessLayerArn
    ->Option.map(arn => [arn->Pulumi.Input.make])
    ->Option.getOr([])
    ->Pulumi.Input.make

  let appsyncEndpoint = AppSync_EventsApi.httpEndpoint(eventsApi)

  let lambda = Lambda.Function.make(
    ~name=name ++ "StateTopicLambda",
    ~args={
      handler: "index.handler"->Pulumi.Input.make,
      runtime: "nodejs22.x"->Pulumi.Input.make,
      code: code->Pulumi.Input.make,
      sourceCodeHash: sourceCodeHash->Pulumi.Input.make,
      role: lambdaRole.arn->Pulumi.Output.asInput,
      memorySize: 128->Pulumi.Input.make,
      timeout: 30->Pulumi.Input.make,
      layers,
      tags: AWS.Tags.make(~name=name ++ "StateTopic", ReventlessCore.QueryDb.componentType),
      environment: (
        {
          Lambda.Function.variables: Dict.fromArray([
            ("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make),
            ("APPSYNC_ENDPOINT", appsyncEndpoint->Pulumi.Output.asInput),
          ]),
        }: Lambda.Function.functionEnvironment
      )->Pulumi.Input.make,
    },
    ~opts,
  )

  // EventSourceMapping: DynamoDB Stream → StateTopic Lambda
  // Uses streamArn (not streamResource.urn which holds the table ARN).
  let _esm = EventSourceMapping.make(
    ~name=name ++ "Stream2" ++ name ++ "StateTopic",
    ~args={
      EventSourceMapping.functionName: lambda.arn->Pulumi.Output.asInput,
      eventSourceArn: streamArn->Pulumi.Output.asInput,
      startingPosition: LATEST,
    },
    ~opts=Some(opts),
  )
}
