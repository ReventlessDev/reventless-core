open PulumiAws.PolicyDocument
open ReventlessCore.Adapter
open Adapter_Helpers

let log = ReventlessCore.Logger.fromEnv()

let toResources = (eventTopics: ReventlessCore.EventTopic.allOutputs) =>
  eventTopics
  ->Dict.valuesToArray
  ->Array.flatMap(outputs => outputs.resources)
  ->ReventlessCore.Adapter.resourcesToResolvedOutput

let createQueuePolicy = (queue: PulumiAws.SQS.Queue.t, name, opts) => {
  // The document is a *value* derived from the resolved ARN, so it is built in
  // an apply. The QueuePolicy itself stays outside: passing `queue.id` as an
  // Output is what registers the policy -> queue dependency, without which
  // Pulumi has no ordering constraint and can delete the queue first on a
  // replacement, leaving the policy's delete polling a queue that is gone.
  let queuePolicyDocument = queue.arn->Pulumi.Output.apply(queueArn => {
    // Scopes cross-plugin SNS sources to this account (aws:SourceAccount) and
    // to topic names following the Reventless EventTopic naming convention
    // (aws:SourceArn arnLike).
    let accountId = queueArn->accountIdOfQueueArn
    PulumiAws.PolicyDocument.make(
      ~id=name ++ "QueuePolicy",
      ~statements=[
        // Single statement allows SendMessage from any SNS topic owned by
        // this AWS account whose name matches the Reventless EventTopic
        // naming convention. A per-topic arnEquals list would require a
        // redeploy of the receiving plugin whenever the platform's
        // manageSubscriptions hook creates a cross-plugin SNS subscription at
        // runtime. Security boundary: SourceAccount keeps third-party-account
        // topics out; ArnLike + SNS service principal further narrows accepted
        // senders to in-account EventTopic resources.
        {
          sid: "AllowReceiveSnsEvents",
          principal: Principals({
            service: PrincipalIds([AWS.SNS.principal]),
          }),
          effect: Allow,
          actions: Actions(["sqs:SendMessage"]),
          resources: Resource(queueArn),
          conditions: {
            stringEquals: [("aws:SourceAccount", ConditionValue(accountId))]->Dict.fromArray,
            arnLike: [
              ("aws:SourceArn", ConditionValue(`arn:aws:sns:*:${accountId}:*EventTopic-*`)),
            ]->Dict.fromArray,
          },
        },
      ],
    )->toJsonString
  })
  let _queuePolicy = PulumiAws.SQS.QueuePolicy.make(
    ~name,
    ~args={
      queueUrl: queue.id->Pulumi.Output.asInput,
      policy: queuePolicyDocument->Pulumi.Output.asInput,
    },
    ~opts=Some(opts),
  )
}

let subscribeQueue2SnsTopic = (
  queue,
  name,
  resources: array<ReventlessInfra.Adapter.resolvedResource>,
  opts,
) => {
  let _snsTopicSubscriptions = resources->Array.map(resource => {
    log.debug(~comp="EventCollector", `subscribeToSnsTopic: ${name} -> ${resource.name}`)
    let subscription = Util_SQS.subscribeToSnsTopic(
      ~queue,
      ~targetName=name,
      ~sourceName=resource.name,
      ~topic=resource->ReventlessCore.AdapterDeploytime.resolvedToResource,
      ~opts,
    )
    subscription.id->Pulumi.Output.apply(id => log.debug(~comp="EventCollector", `created SNS subscription: ${id} ${name}`))
  })
}

let connectSqsQueue2SnsTopics = (queue: PulumiAws.SQS.Queue.t, name, eventTopics, opts) => {
  // The policy grants SendMessage to any in-account EventTopic by naming
  // convention, so it does not depend on the resolved topic resources and is
  // created outside the apply. Only the SNS subscriptions need them.
  queue->createQueuePolicy(name, opts)
  let _ =
    (eventTopics->toResources, queue.id)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((eventTopicResources, queueId)) => {
      log.debug(
        ~comp="EventCollector",
        `connectSqsQueue2SnsTopics ${queueId}: ${eventTopicResources
          ->Array.length
          ->Int.toString} topic resource(s)`,
      )
      queue->subscribeQueue2SnsTopic(name, eventTopicResources->snsResources, opts)
    })
}

// The EventCollector's transport wiring: one mapping per stream source plus one
// per buffer queue. `~component=name` keeps them attributed to the collector they
// feed, not to the mapping's own generated name.
let esmTags = (name, esmName) =>
  AWS.Tags.make(
    ~name=esmName,
    ~kind=ReventlessCore.EventCollector.componentType,
    ~role=EventSourceMapping,
    ~component=name,
  )

let connectLambda = (
  lambda: Pulumi.Output.t<PulumiAws.Lambda.Function.t>,
  name: string,
  lambdaRole: PulumiAws.IAM.Role.t,
  queues: array<PulumiAws.SQS.Queue.t>,
  eventTopics: ReventlessCore.EventTopic.allOutputs,
  resources: array<ReventlessInfra.Adapter.resource>,
  opts: Pulumi.CustomResourceOptions.t,
) => {
  // The three input sets are resolved SEPARATELY, and each resource is gated on
  // the narrowest one it actually needs.
  //
  // They used to share one `Pulumi.Output.all3` apply that created the role policy
  // and every EventSourceMapping. An apply whose inputs are unknown does not run
  // during preview, and a resource the program never registers reads as a DELETE —
  // so an unknown in ANY of the three deleted ALL of them, including mappings that
  // do not depend on it. `targetResources` (the collector's own view tables) is the
  // one that goes unknown in practice: switching a plugin's slices to the stream
  // builder gives each view table a computed `streamArn`, which Pulumi cannot know
  // in the preview that enables it, so the plugin's event-log mapping and role
  // policy — neither of which reads a view table — vanished from that preview.
  let eventTopicResourcesOutput = eventTopics->toResources
  let queueArnsOutput = queues->Array.map(queue => queue.arn)->Pulumi.Output.all
  let targetResourcesOutput = resources->ReventlessCore.Adapter.resourcesToResolvedOutput

  // Only the policy DOCUMENT needs all three. The RolePolicy resource itself is
  // registered at top level with the document as an Output input, so an unknown
  // input previews as "update, value unknown" instead of removing the policy.
  let lambdaPolicyJson =
    (eventTopicResourcesOutput, queueArnsOutput, targetResourcesOutput)
    ->Pulumi.Output.all3
    ->Pulumi.Output.flatMap(((eventTopicResources, queueArns, resources)) => {
      log.debug(
        ~comp="EventCollector",
        `connectLambda ${name}: ${eventTopicResources->Array.length->Int.toString} topic resource(s), ${resources->Array.length->Int.toString} resource(s)`,
      )

      let dynamoDbStreamResources = eventTopicResources->dynamoDbStreamResources
      let targetSnsResources = resources->snsResources
      let targetSqsResources = resources->sqsResources
      let targetDynamoDbResources = resources->dynamoDbResources

      let allowLambdaReadDynamoDbStream =
        dynamoDbStreamResources->Array.length > 0
          ? Some(
              PulumiAws.PolicyDocument.make(
                ~id=name ++ "LambdaDynamoDbStreamPolicy",
                ~statements=[
                  {
                    sid: "AllowLambdaReadDynamoDbStream",
                    effect: Allow,
                    actions: Actions([
                      "dynamodb:DescribeStream",
                      "dynamodb:GetRecords",
                      "dynamodb:GetShardIterator",
                      "dynamodb:ListStreams",
                    ]),
                    resources: Resources(dynamoDbStreamResources->urns),
                  },
                ],
              ),
            )
          : None

      let allowLambdaReadWriteDynamoDb =
        targetDynamoDbResources->Array.length > 0
          ? Some(
              PulumiAws.PolicyDocument.make(
                ~id=name ++ "LambdaAllowDynamoDbWrite",
                ~statements=[
                  {
                    sid: "AllowLambdaReadWriteDynamoDb",
                    effect: Allow,
                    actions: Actions([
                      "dynamodb:GetItem",
                      "dynamodb:Query",
                      "dynamodb:Scan",
                      "dynamodb:BatchGetItem",
                      "dynamodb:PutItem",
                      "dynamodb:UpdateItem",
                      "dynamodb:DeleteItem",
                      "dynamodb:BatchWriteItem",
                    ]),
                    resources: Resources(targetDynamoDbResources->urns),
                  },
                ],
              ),
            )
          : None

      let allowLambdaPublishSNS =
        targetSnsResources->Array.length > 0
          ? Some(
              PulumiAws.PolicyDocument.make(
                ~id=name ++ "PublishSNS",
                ~statements=[
                  {
                    sid: "AllowLambdaPublishSNS",
                    effect: Allow,
                    actions: Action("sns:Publish"),
                    resources: Resources(targetSnsResources->urns),
                  },
                ],
              ),
            )
          : None

      let allowLambdaSendSQS =
        targetSqsResources->Array.length > 0
          ? Some(
              PulumiAws.PolicyDocument.make(
                ~id=name ++ "SendSQS",
                ~statements=[
                  {
                    sid: "AllowLambdaSendSQS",
                    effect: Allow,
                    actions: Action("sqs:SendMessage"),
                    resources: Resources(targetSqsResources->urns),
                  },
                ],
              ),
            )
          : None

      let allowLambdaReceiveSQS =
        queueArns->Array.length > 0
          ? Some(
              PulumiAws.PolicyDocument.make(
                ~id=name ++ "LambdaSQSPolicy",
                ~statements=[
                  {
                    sid: "AllowLambdaReceiveSQS",
                    effect: Allow,
                    actions: Actions([
                      "sqs:ReceiveMessage",
                      "sqs:DeleteMessage",
                      "sqs:GetQueueAttributes",
                    ]),
                    resources: Resources(queueArns),
                  },
                ],
              ),
            )
          : None

      PulumiAws.PolicyDocument.mergePolicyDocuments(
        name ++ "LambdaPolicy",
        [
          Some(PulumiAws.Lambda.defaultLoggingPolicyDocument),
          allowLambdaReceiveSQS,
          allowLambdaReadDynamoDbStream,
          allowLambdaReadWriteDynamoDb,
          allowLambdaPublishSNS,
          allowLambdaSendSQS,
        ]->Array.keepSome,
      )
    })

  let _lambdaPolicy = PulumiAws.IAM.RolePolicy.make(
    ~name,
    ~args={
      policy: lambdaPolicyJson->Pulumi.Output.asInput,
      role: lambdaRole.id->Pulumi.Output.asInput,
    },
    ~opts,
  )

  // The mappings read nothing but the event topics, so that is all they wait for.
  // They cannot be hoisted out of an apply the way the policy can: an ESM's Pulumi
  // name is derived from the resolved source name, so a brand-new event log still
  // previews without them — inherent, and no longer reachable from a view table.
  //
  // Attribution is captured at THIS call, not inside the callback: by the time an
  // apply runs, the builder's construct has returned and the ambient context is
  // empty. (The top-level policy above is created while it is still ambient.)
  let _ =
    eventTopicResourcesOutput->ReventlessCore.ResourceAttribution_Deploytime.applyAttributed(
      eventTopicResources =>
        eventTopicResources
        ->dynamoDbStreamResources
        ->Array.map(dynamoDbStreamResource =>
          Util_EventSourceMapping.subscribe(
            ~lambda,
            ~targetName=name,
            ~sourceName=dynamoDbStreamResource.name,
            ~source=dynamoDbStreamResource->ReventlessCore.AdapterDeploytime.resolvedToResource,
            ~tags=esmTags(
              name,
              dynamoDbStreamResource.name->ReventlessCore.Util.baseName ++ ("2" ++ name),
            ),
            ~opts,
          )
        ),
    )

  let subscriptionResources = queues->Array.mapWithIndex((queue, idx) => {
    let esmName = queues->Array.length > 1 ? `${name}Sqs${Int.toString(idx)}` : name
    Util_EventSourceMapping.subscribeSqs(
      ~lambda,
      ~name=esmName,
      ~queue,
      ~tags=esmTags(name, esmName),
      ~opts,
    )
  })

  subscriptionResources
}
