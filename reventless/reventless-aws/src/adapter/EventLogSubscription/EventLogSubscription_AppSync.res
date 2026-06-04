// EventLogSubscription_AppSync.res
// Source A: raw event stream subscriptions (SNS EventTopic → AppSync Events API).
//
// Creates deploy-time resources for one EventLog entry (aggregate or DCB):
//   SNS EventTopic ──► SQS buffer ──► Lambda ──► AppSync Events channel
//
// Usage in the plugin builder (once per entry in eventLogEntries):
//   EventLogSubscription_AppSync.make(
//     ~name="CatalogPlugin",           // displayName from eventLogSchemaEntry
//     ~topicName="CatalogPlugin",      // AppSync Events channel name (matches displayName)
//     ~eventTopicOutputs,              // EventTopic.outputs (resources[0] is the SNS topic)
//     ~api,
//     ~opts,
//   )

open PulumiAws

// ── Handler code ─────────────────────────────────────────────────────────────
//
// Receives SNS-via-SQS records (rawMessageDelivery=true → body IS the event JSON).
// Publishes {position, eventType, payload, originatorSlice} to AppSync Events channel.
// The "originatorSlice" tag is injected by StateChangeSlice_Callback.encodeEvent.

let makeHandlerCode = (~topicName: string): string => {
  // Mirrors StateTopic_AppSync.pathSegment: AppSync Events channel segments
  // allow only [A-Za-z0-9-]. Today's event-log displayNames are bare
  // PascalCase identifiers (Catalog, Ordering, Plugin) so the rule is a no-op
  // in practice — kept in lock-step prophylactically so a future displayName
  // carrying `@/./:` etc. doesn't hit the same silent-drop the Plugins admin
  // RM did when StateTopic still only normalised underscores.
  let channelName = topicName->String.replaceRegExp(%re("/[^A-Za-z0-9-]/g"), "-")
  `
import { createHmac, createHash } from "node:crypto";

const CHANNEL = "/default/${channelName}";
const APPSYNC_ENDPOINT = process.env.APPSYNC_ENDPOINT;
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
    let body;
    try {
      body = JSON.parse(record.body);
    } catch (e) {
      console.error("EventLogSubscription: failed to parse record body", record.body, e);
      continue;
    }
    const originatorSlice = body.tags?.find(t => t.key === "originatorSlice")?.value;
    const payload = { position: body.position, eventType: body.eventType, payload: body.data, originatorSlice: originatorSlice ?? null };
    const reqBody = JSON.stringify({ id: record.messageId, channel: CHANNEL, events: [JSON.stringify(payload)] });
    const auth = await signedHeaders(url.hostname, "/event", reqBody);
    const res = await fetch(APPSYNC_ENDPOINT + "/event", {
      method: "POST",
      headers: { accept: "application/json, text/javascript", "content-encoding": "amz-1.0", "content-type": "application/json; charset=UTF-8", ...auth },
      body: reqBody,
    });
    if (!res.ok) {
      const txt = await res.text();
      console.error("EventLogSubscription publish failed:", res.status, txt);
    }
  }
}
`
}

// ── Deploy-time resource builder ──────────────────────────────────────────────

let make = (
  ~name: string,
  ~topicName: string,
  ~eventTopicOutputs: ReventlessInfra.EventTopic.outputs,
  ~eventsApi: AppSync_EventsApi.t,
  ~opts: Pulumi.CustomResourceOptions.t,
) => {
  // SQS buffer queue with redrive to shared dead-letter queue
  let queue = SQS.Queue.make(
    ~name=name ++ "EventLogSubQueue",
    ~args={
      SQS.Queue.visibilityTimeoutSeconds: 60->Pulumi.Input.make,
      redrivePolicy: Util_DeadLetterQueue.queue.arn
      ->Pulumi.Output.apply(dlqArn =>
        SQS.Queue.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      )
      ->Pulumi.Output.asInput,
      sqsManagedSseEnabled: false->Pulumi.Input.make,
    },
    ~opts,
  )

  // SQS queue policy — allow SNS to send messages
  let snsResource = eventTopicOutputs.resources->Array.getUnsafe(0)
  let _ =
    (queue.arn, queue.id, snsResource.urn)
    ->Pulumi.Output.all3
    ->Pulumi.Output.apply(((queueArn, queueId, snsUrn)) => {
      open PolicyDocument
      let _queuePolicy = SQS.QueuePolicy.make(
        ~name=name ++ "EventLogSubQueuePolicy",
        ~args={
          queueUrl: queueId->Pulumi.Input.make,
          policy: PolicyDocument.make(
            ~id=name ++ "EventLogSubQueuePolicy",
            ~statements=[
              {
                sid: "AllowSNSSend",
                principal: Principals({service: PrincipalIds([AWS.SNS.principal])}),
                effect: Allow,
                actions: Actions(["sqs:SendMessage"]),
                resources: Resource(queueArn),
                conditions: {
                  arnEquals: [
                    ("aws:SourceArn", ConditionValues([snsUrn])),
                  ]->Dict.fromArray,
                },
              },
            ],
          )
          ->PolicyDocument.toJsonString
          ->Pulumi.Input.make,
        },
        ~opts=Some(opts),
      )
    })

  // SNS → SQS subscription (raw delivery so body IS the event JSON)
  let _subscription = Util_SQS.subscribeToSnsTopic(
    ~queue,
    ~targetName=name ++ "EventLogSub",
    ~sourceName=name,
    ~topic=snsResource,
    ~opts,
  )

  // IAM role for the Lambda
  let lambdaRole = IAM.Role.makeWithDefaultPolicy(
    ~name=name ++ "EventLogSubRole",
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
    ~opts,
  )

  // IAM policy: SQS receive + AppSync Events publish
  let _ =
    (
      queue.arn,
      eventsApi.api.apiArn,
    )
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((queueArn, apiArn)) => {
      open PolicyDocument
      let _rolePolicy = IAM.RolePolicy.make(
        ~name=name ++ "EventLogSubPolicy",
        ~args={
          IAM.RolePolicy.policy: PolicyDocument.make(
            ~id=name ++ "EventLogSubPolicy",
            ~statements=[
              {
                sid: "AllowLambdaLogging",
                effect: Allow,
                actions: Action("logs:*"),
                resources: Resource("arn:aws:logs:*:*:*"),
              },
              {
                sid: "AllowReceiveSQS",
                effect: Allow,
                actions: Actions([
                  "sqs:ReceiveMessage",
                  "sqs:DeleteMessage",
                  "sqs:GetQueueAttributes",
                ]),
                resources: Resource(queueArn),
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

  // Lambda function — processes SQS records (SNS events) → AppSync Events channel
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
    ~name=name ++ "EventLogSubLambda",
    ~args={
      handler: "index.handler"->Pulumi.Input.make,
      runtime: "nodejs22.x"->Pulumi.Input.make,
      code: code->Pulumi.Input.make,
      sourceCodeHash: sourceCodeHash->Pulumi.Input.make,
      role: lambdaRole.arn->Pulumi.Output.asInput,
      memorySize: 128->Pulumi.Input.make,
      timeout: 30->Pulumi.Input.make,
      layers,
      tags: AWS.Tags.make(~name=name ++ "EventLogSub", ReventlessCore.EventTopic.componentType),
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

  // EventSourceMapping: SQS → Lambda
  let lambdaOutput = lambda->Pulumi.Output.make
  let _esm = Util_EventSourceMapping.subscribeSqs(
    ~lambda=lambdaOutput,
    ~name=name ++ "EventLogSubESM",
    ~queue,
    ~opts,
  )
}
