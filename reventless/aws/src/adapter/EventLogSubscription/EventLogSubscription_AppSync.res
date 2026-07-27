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

// AppSync Events channel segments allow only [A-Za-z0-9-]. Today's event-log
// displayNames are bare PascalCase identifiers (Catalog, Ordering, Plugin) so
// the rule is a no-op in practice — kept prophylactically so a future displayName
// carrying `@/./:` etc. doesn't hit a silent-drop. Mirrors
// AppSyncEventsSigner_Ops.pathSegment (the runtime handler's equivalent).
let channelNameOf = (topicName: string): string =>
  topicName->String.replaceRegExp(%re("/[^A-Za-z0-9-]/g"), "-")

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
      tags: AWS.Tags.make(
        ~name=name ++ "EventLogSubQueue",
        ~kind=ReventlessCore.EventTopic.componentType,
        ~role=EventLogSubscription,
        ~component=name,
      ),
    },
    ~opts,
  )

  // SQS queue policy — allow SNS to send messages
  let snsResource = eventTopicOutputs.resources->Array.getUnsafe(0)
  // The document is a *value* derived from resolved ARNs, so it is built in an
  // apply. The QueuePolicy itself stays outside: passing `queue.id` as an Output
  // is what registers the policy -> queue dependency, without which Pulumi has
  // no ordering constraint and can delete the queue first on a replacement,
  // leaving the policy's delete polling a queue that no longer exists.
  let queuePolicyDocument =
    (queue.arn, snsResource.urn)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((queueArn, snsUrn)) => {
      open PolicyDocument
      PolicyDocument.make(
        ~id=name ++ "EventLogSubQueuePolicy",
        ~statements=[
          {
            sid: "AllowSNSSend",
            principal: Principals({service: PrincipalIds([AWS.SNS.principal])}),
            effect: Allow,
            actions: Actions(["sqs:SendMessage"]),
            resources: Resource(queueArn),
            conditions: {
              arnEquals: [("aws:SourceArn", ConditionValues([snsUrn]))]->Dict.fromArray,
            },
          },
        ],
      )->PolicyDocument.toJsonString
    })
  let _queuePolicy = SQS.QueuePolicy.make(
    ~name=name ++ "EventLogSubQueuePolicy",
    ~args={
      queueUrl: queue.id->Pulumi.Output.asInput,
      policy: queuePolicyDocument->Pulumi.Output.asInput,
    },
    ~opts=Some(opts),
  )

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
    ~tags=AWS.Tags.make(
      ~name=name ++ "EventLogSubRole",
      ~kind=ReventlessCore.EventTopic.componentType,
      ~role=Identity,
      ~component=name,
    ),
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

  // Lambda function — processes SQS records (SNS events) → AppSync Events channel.
  // Bundle reventless-aws (the compiled `_Ops` handler + its node:crypto signer
  // live inside it) and re-export its `handler`; buildCodeArchive ships the ESM
  // resolve-hook so `@rescript/runtime` resolves from the layer.
  let channelName = channelNameOf(topicName)
  let packageDirs = Dict.fromArray([
    ("@reventlessdev/reventless-aws", Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws")),
  ])
  let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync_Ops.res.mjs",
    ~packageDirs,
  )

  let layers =
    Lambda.reventlessLayerArn
    ->Option.map(arn => [arn->Pulumi.Input.make])
    ->Option.getOr([])
    ->Pulumi.Input.make

  let appsyncEndpoint = AppSync_EventsApi.httpEndpoint(eventsApi)

  let lambda = Lambda.Function.make(
    ~name=name ++ "EventLogSubscriber",
    ~args={
      handler: "index.handler"->Pulumi.Input.make,
      runtime: "nodejs22.x"->Pulumi.Input.make,
      code: code->Pulumi.Input.make,
      sourceCodeHash: sourceCodeHash->Pulumi.Input.make,
      role: lambdaRole.arn->Pulumi.Output.asInput,
      memorySize: 128->Pulumi.Input.make,
      timeout: 30->Pulumi.Input.make,
      layers,
      tags: AWS.Tags.make(~name=name ++ "EventLogSub", ~kind=ReventlessCore.EventTopic.componentType, ~role=EventLogSubscription, ~component=name),
      environment: (
        {
          Lambda.Function.variables: Dict.fromArray([
            ("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make),
            ("APPSYNC_ENDPOINT", appsyncEndpoint->Pulumi.Output.asInput),
            ("EVENT_LOG_CHANNEL", channelName->Pulumi.Input.make),
            ("NODE_OPTIONS", Util_Bundle.esmLoaderNodeOptions->Pulumi.Input.make),
            ("ESM_FALLBACK_DIRS", Util_Bundle.esmFallbackDirs->Pulumi.Input.make),
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
    ~name=name ++ "EventLogSubEventSourceMapping",
    ~queue,
    ~tags=AWS.Tags.make(
      ~name=name ++ "EventLogSubEventSourceMapping",
      ~kind=ReventlessCore.EventTopic.componentType,
      ~role=EventSourceMapping,
      ~component=name,
    ),
    ~opts,
  )
}
