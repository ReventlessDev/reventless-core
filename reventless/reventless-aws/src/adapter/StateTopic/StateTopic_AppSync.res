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
//     ~topicName="catalog_Product",  // AppSync Events channel name (= returnTypeName)
//     ~allQueryDbs,
//     ~api,
//     ~opts,
//   )

open PulumiAws

// ── Handler code ─────────────────────────────────────────────────────────────
//
// Processes DynamoDB Stream records → publishes full NewImage to AppSync Events channel.
// The channel name is injected via TOPIC_NAME env var at deploy time.
//
// SDK: @aws-sdk/client-appsync-events (lazy-imported — keeps closure serialisable).
// Endpoint: APPSYNC_ENDPOINT env var = "https://{eventsApi.dns.http}" (full URL, no path).
// The AppSyncEventsClient handles the /event path internally.

let makeHandlerCode = (~topicName: string): string => `
import { unmarshall } from "@aws-sdk/util-dynamodb";

const TOPIC_NAME = "${topicName}";
const APPSYNC_ENDPOINT = process.env.APPSYNC_ENDPOINT;
const AWS_REGION = process.env.AWS_REGION ?? "eu-west-1";

let _client = null;

async function getClient() {
  if (_client) return _client;
  const { AppSyncEventsClient } = await import("@aws-sdk/client-appsync-events");
  _client = new AppSyncEventsClient({ endpoint: APPSYNC_ENDPOINT, region: AWS_REGION });
  return _client;
}

export async function handler(event) {
  const { PublishEvents } = await import("@aws-sdk/client-appsync-events");
  const client = await getClient();
  for (const record of event.Records) {
    if (record.eventName === "REMOVE") continue;
    const newImage = unmarshall(record.dynamodb.NewImage);
    await client.send(new PublishEvents({
      channelNamespace: "default",
      channelName: TOPIC_NAME,
      events: [JSON.stringify(newImage)],
    }));
  }
}
`

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

  // IAM role for the Lambda (Lambda service principal)
  let lambdaRole = IAM.Role.makeWithDefaultPolicy(
    ~name=name ++ "StateTopicRole",
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
    ~opts,
  )

  // IAM policy: read DynamoDB stream + publish to AppSync Events API
  let _ =
    (
      streamResource.urn,
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
  let lambdaOutput = lambda->Pulumi.Output.make
  let _esm = Util_EventSourceMapping.subscribe(
    ~lambda=lambdaOutput,
    ~targetName=name ++ "StateTopic",
    ~sourceName=streamResource.name->Pulumi.Output.get,
    ~source=streamResource,
    ~opts,
  )
}
