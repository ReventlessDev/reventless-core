// StateTopic_AppSync.res
// Source B: state-change subscriptions (QueryDb DynamoDB Stream → AppSync Events API).
//
// Creates deploy-time resources for one ReadModel or StateViewSlice:
//   QueryDb DynamoDB table (stream-enabled) → Lambda → AppSync Events channel
//
// Supersedes StateTopicPublisher_DynamoDbStream (stream resource discovery) and
// StateTopicPublisher (re-export shim) — both deleted; the lookup now lives here.
//
// Prerequisites:
//   - The QueryDb must use QueryDbStorage_DynamoDbStream so its resource has a
//     streamArn (StreamSource resourceInfo).
//   - Phase 1 makeSubscriptionResolver must be called with the appropriate
//     subscriptionFilter for the matching Subscription.on{Type}_stateChanged field.
//
// Usage in the plugin builder (after allQueryDbs are assembled):
//   StateTopic_AppSync.make(
//     ~readModelName="Product",      // QueryDb key = ReadModel Spec.name
//     ~topicName="catalog_Product",  // AppSync Events channel (underscores → hyphens)
//     ~allQueryDbs,
//     ~api,
//     ~opts,
//   )

open PulumiAws

// ── Handler code ─────────────────────────────────────────────────────────────
//
// Processes DynamoDB Stream records → publishes full NewImage to AppSync Events channel.
// Channel name: /default/{topicName} where topicName has underscores replaced with hyphens
// (AppSync Events channels do not allow underscores in the channel path).
//
// Uses native Node.js crypto + fetch with SigV4 — no extra SDK packages needed.
// Credentials come from the Lambda execution role via the process.env AWS_* variables.

let makeHandlerCode = (~topicName: string): string => {
  // AppSync Events channels cannot contain underscores — replace with hyphens.
  let channelName = topicName->String.replaceAll("_", "-")
  `
import { createHmac, createHash } from "node:crypto";
import { unmarshall } from "@aws-sdk/util-dynamodb";

const CHANNEL = "/default/${channelName}";
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

export async function handler(event) {
  const url = new URL(APPSYNC_ENDPOINT);
  for (const record of event.Records) {
    if (record.eventName === "REMOVE") continue;
    const newImage = unmarshall(record.dynamodb.NewImage);
    const body = JSON.stringify({ id: record.eventID, channel: CHANNEL, events: [JSON.stringify(newImage)] });
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
