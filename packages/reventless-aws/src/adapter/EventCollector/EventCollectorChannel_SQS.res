type callbackEvent = PulumiAws.Lambda.CallbackFunction.event
type channelParts = Util.SQS.channelParts
type runtimeParts = Util.Lambda.runtimeParts

let subscribe = (
  ~name,
  ~eventTopics,
  ~channel: Reventless.EventCollector_Adapter.channel<
    callbackEvent,
    'context,
    channelParts,
    runtimeParts,
  >,
  ~runtime: Reventless.Runtime.environment<runtimeParts>,
  ~resources: array<ReventlessSpec.Adapter.resource>,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let queue = channel.parts.queue
  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  let eventTopicResources =
    eventTopics
    ->(Js.Dict.map((eventTopic: Reventless.EventTopic.outputs) => eventTopic.resources, _))
    ->Reventless.Util.Adapter.partitionSupportedResources([
      AWS.DynamoDbStream.service,
      AWS.SNS.service,
    ])

  let attachPolicies =
    (
      eventTopicResources,
      queue.arn,
      queue.id,
      resources->Reventless.Adapter.resourcesToUnwrappedOutput,
    )
    ->Pulumi.Output.all4
    ->Pulumi.Output.apply(((
      (supportedResources, errorResources),
      queueArn,
      queueId,
      resources,
    )) => {
      let (snsResources, otherResources) =
        supportedResources->Reventless.Util.Adapter.partitionUnwrappedResourcesByService(
          AWS.SNS.service,
        )

      let _snsTopicSubscriptions = snsResources->Belt.Array.map(((sourceName, topic)) =>
        Util_SQS.subscribeToSnsTopic(
          ~queue,
          ~targetName=name,
          ~sourceName,
          ~topic=topic
          ->Util.SNS.findTopicInUnwrappedResources
          ->Reventless.AdapterDeploytime.unwrappedToResource,
          ~opts,
        )
      )

      let _eventSourceMappings = otherResources->Belt.Array.map(((sourceName, resources)) =>
        Util_EventSourceMapping.subscribe(
          ~lambda,
          ~targetName=name,
          ~sourceName,
          ~source=resources
          ->Util.DynamoDbStream.findUnwrappedResource
          ->Reventless.AdapterDeploytime.unwrappedToResource,
          ~opts,
        )
      )

      let attachQueuePolicy = {
        open PulumiAws.PolicyDocument
        PulumiAws.SQS.QueuePolicy.make(
          ~name=name ++ "QueuePolicy",
          ~args={
            queueUrl: queueId->Pulumi.Input.make,
            policy: PulumiAws.PolicyDocument.make(
              ~id=name ++ "QueuePolicy",
              ~statements=[
                {
                  sid: "AllowReceiveEvents",
                  principal: Principals({
                    service: PrincipalIds([
                      AWS.CloudwatchEventRule.principal,
                      AWS.Lambda.principal,
                      AWS.SNS.principal,
                    ]),
                  }),
                  effect: Allow,
                  actions: Actions(["sqs:SendMessage"]),
                  resources: Resource(queueArn),
                },
              ],
            )
            ->toJsonString
            ->Pulumi.Input.make,
          },
          ~opts=Some(opts),
        )
      }

      let lambdaDynamoDbStreamPolicyDocuments = otherResources->Belt.Array.map(((
        _sourceName,
        sources,
      )) => {
        let source = sources->Array.getUnsafe(0)
        open PulumiAws.PolicyDocument
        PulumiAws.PolicyDocument.make(
          ~id=name ++ source.name ++ "Policy",
          ~statements=[
            {
              sid: "AllowLambdaToReadStream" ++ source.name->String.split("-")->Array.getUnsafe(0),
              effect: Allow,
              actions: Actions([
                "dynamodb:DescribeStream",
                "dynamodb:GetRecords",
                "dynamodb:GetShardIterator",
                "dynamodb:ListStreams",
              ]),
              resources: Resource(source.urn),
            },
          ],
        )
      })

      let lambdaQueuePolicyDocument = {
        open PulumiAws.PolicyDocument
        PulumiAws.PolicyDocument.make(
          ~id=name ++ "LambdaSQSPolicy",
          ~statements=[
            {
              sid: "AllowLambdaReceiveSQSMessage",
              effect: Allow,
              actions: Actions([
                "sqs:ReceiveMessage",
                "sqs:DeleteMessage",
                "sqs:GetQueueAttributes",
              ]),
              resources: Resource(queueArn),
            },
          ],
        )
      }

      let attachLambdaPolicy = PulumiAws.IAM.RolePolicy.make(
        ~name=name ++ "LambdaPolicy",
        ~args={
          policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
            name ++ "LambdaPolicy",
            lambdaDynamoDbStreamPolicyDocuments->Belt.Array.concat([
              PulumiAws.Lambda.defaultLoggingPolicyDocument,
              lambdaQueuePolicyDocument,
            ]),
          )->Pulumi.Output.asInput,
          role: lambdaRole.id->Pulumi.Output.asInput,
        },
        ~opts,
      )

      if errorResources->Belt.Array.length > 0 {
        let eventTopicNames = errorResources->Js.Array2.joinWith(",")
        Js.Exn.raiseError(__MODULE__ ++ ` cannot connect to EventTopic(s) ${eventTopicNames}`)
      }

      (attachLambdaPolicy, attachQueuePolicy)
    })

  let resource =
    attachPolicies
    ->Pulumi.Output.flatMap(((attachLambdaPolicy, attachQueuePolicy)) =>
      (attachLambdaPolicy.id, attachQueuePolicy.id, lambda)
      ->Pulumi.Output.all3
      ->Pulumi.Output.apply(((_, _, lambda)) => {
        queue
        ->PulumiAws.SQS.Queue.onEvent(~name, ~handler=lambda, ~opts)
        ->Util.SQS.Subscription.toResource
      })
    )
    ->Reventless.Adapter.outputToResource

  [resource]
}

let make: Reventless.EventCollector_Adapter.channelMaker<
  callbackEvent,
  'context,
  channelParts,
  runtimeParts,
> = (~name, ~opts) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let queue = PulumiAws.SQS.Queue.make(
    ~name,
    ~args={
      PulumiAws.SQS.Queue.visibilityTimeoutSeconds: 120->Pulumi.Input.make,
      redrivePolicy: Util_DeadLetterQueue.queue.arn
      ->Pulumi.Output.apply(dlqArn =>
        PulumiAws.SQS.Queue.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      )
      ->Pulumi.Output.asInput,
      sqsManagedSseEnabled: false->Pulumi.Input.make,
      tags: AWS.Tags.make(~name, Reventless.EventCollector.componentType),
    },
    ~opts,
  )

  {
    Reventless.EventCollector_Adapter.parts: {queue: queue},
    resources: [queue->Util_SQS.toResource],
    enqueueEvent: queue
    ->Util_SQS.toRuntimeQueueOutput
    ->Pulumi.Output.apply(runtimeQueue =>
      EventCollectorChannel_SQS_Runtime.enqueueEvent(runtimeQueue, ...)
    ),
    subscribe,
    handleChannelEvent: handleEvents =>
      queue
      ->Util_SQS.toRuntimeQueueOutput
      ->Pulumi.Output.apply(runtimeQueue =>
        runtimeQueue->(
          EventCollectorChannel_SQS_Runtime.handleDynamoDbOrSqsEvent(handleEvents, ...)
        )
      ),
  }
}
