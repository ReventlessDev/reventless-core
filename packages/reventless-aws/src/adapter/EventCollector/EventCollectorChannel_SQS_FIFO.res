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
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let queue = channel.parts.queue
  let lambda = runtime.parts.lambda
  let _ =
    lambda.name->Pulumi.Output.apply(lambdaName =>
      Js.log2("EventCollectorChannel_SQS_FIFO: lambdaName:", lambdaName)
    )
  let lambdaRole = runtime.parts.lambdaRole

  let eventTopicResources =
    eventTopics
    ->(Js.Dict.map((eventTopic: Reventless.EventTopic.outputs) => eventTopic.resources, _))
    ->Reventless.Util.Adapter.partitionSupportedResources([
      AWS.DynamoDbStream.service,
      AWS.SNS_FIFO.service,
    ])

  let attachPolicies =
    (eventTopicResources, queue.arn, queue.id)
    ->Pulumi.Output.all3
    ->Pulumi.Output.apply((((supportedResources, errorResources), queueArn, queueId)) => {
      let (snsFifoResources, otherResources) =
        supportedResources->Reventless.Util.Adapter.partitionUnwrappedResourcesByService(
          AWS.SNS_FIFO.service,
        )

      let _snsFifoTopicSubscriptions = snsFifoResources->Belt.Array.map(((sourceName, topic)) =>
        Util_SQS.subscribeToSnsTopic(
          ~queue,
          ~targetName=name,
          ~sourceName,
          ~topic=topic
          ->Util.SNS_FIFO.findTopicInUnwrappedResources
          ->Reventless.AdapterDeploytime.unwrappedToResource,
          ~opts,
        )
      )

      let _eventSourceMappings = otherResources->Belt.Array.map(((sourceName, resources)) =>
        Util_EventSourceMapping.subscribe(
          ~lambda=lambda->Pulumi.Output.make,
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
                  principal: Principals({
                    service: PrincipalId(AWS.SNS.principal),
                  }),
                  effect: Allow,
                  actions: Actions(["sqs:SendMessage"]),
                  resources: Resource(queueArn),
                },
                {
                  principal: Principals({
                    service: PrincipalId(AWS.CloudwatchEventRule.principal),
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
          ~id=name ++ "SQSLambdaPolicy",
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
      (attachLambdaPolicy.id, attachQueuePolicy.id)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(_ => {
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
      PulumiAws.SQS.Queue.fifoQueue: true->Pulumi.Input.make,
      deduplicationScope: MessageGroup,
      fifoThroughputLimit: PerMessageGroupId,
      contentBasedDeduplication: true->Pulumi.Input.make,
      visibilityTimeoutSeconds: 30->Pulumi.Input.make, // TODO fix timeout
      redrivePolicy: Util_DeadLetterQueue.fifoQueue.arn
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
    resources: [queue->Util_SQS_FIFO.toResource],
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
