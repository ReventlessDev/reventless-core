type callbackEvent = PulumiAws.Lambda.CallbackFunction.event

let subscribe = (
  ~name,
  ~eventTopics,
  ~channel: Reventless.EventCollector_Adapter.channel<callbackEvent, 'context>,
  ~runtime: Reventless.Runtime.environment,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let queue =
    channel.resources
    ->Util.SQS_FIFO.findResource
    ->Util.SQS_FIFO.fromResource

  let handler =
    runtime.resources
    ->Util.Lambda.findResource
    ->Util.Lambda.fromResource

  let handlerRole = runtime.resources->Util.IAM_Role.findResource->Util.IAM_Role.fromResource

  let eventTopicResources =
    eventTopics
    ->(Js.Dict.map((eventTopic: Reventless.EventTopic.outputs) => eventTopic.resources, _))
    ->Reventless.Util.Adapter.partitionSupportedResources([
      AWS.DynamoDbStream.service,
      AWS.SNS_FIFO.service,
    ])

  let subscriptionResource =
    (eventTopicResources, queue, queue->Pulumi.Output.flatMap(queue => queue.arn), queue->Pulumi.Output.flatMap(queue => queue.id), handler)
    ->Pulumi.Output.all5
    ->Pulumi.Output.apply((((supportedResources, errorResources), queue, queueArn, queueId, handler)) => {
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
          ~lambda=handler->Pulumi.Output.make,
          ~targetName=name,
          ~sourceName,
          ~source=resources
          ->Util.DynamoDbStream.findUnwrappedResource
          ->Reventless.AdapterDeploytime.unwrappedToResource,
          ~opts,
        )
      )

      let _attachQueuePolicy = {
        open PulumiAws.PolicyDocument
        PulumiAws.SQS.QueuePolicy.make(
          ~name=name ++ "Policy",
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

      let lambdaPolicy = PulumiAws.IAM.Policy.make(
        ~name=name ++ "LambdaPolicy",
        ~args={
          policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
            name ++ "LambdaPolicy",
            lambdaDynamoDbStreamPolicyDocuments->Belt.Array.concat([
              PulumiAws.Lambda.defaultLoggingPolicyDocument,
              lambdaQueuePolicyDocument,
            ]),
          )->Pulumi.Output.asInput,
        },
        ~opts,
      )

      let _attachLambdaPolicy = handlerRole->Pulumi.Output.apply(handlerRole => {
        open PulumiAws
        IAM.RolePolicyAttachment.make(
          ~name=name ++ "LambdaPolicy",
          ~args={
            policyArn: lambdaPolicy.arn->Pulumi.Output.asInput,
            role: handlerRole.id->Pulumi.Output.asInput,
          },
          ~opts=Some(opts),
        )
      })

      if errorResources->Belt.Array.length > 0 {
        let eventTopicNames = errorResources->Js.Array2.joinWith(",")
        Js.Exn.raiseError(__MODULE__ ++ ` cannot connect to EventTopic(s) ${eventTopicNames}`)
      }

      queue
      ->PulumiAws.SQS.Queue.onEvent(~name, ~handler, ~opts)
      ->Util.SQS.Subscription.toResource
    })

  [subscriptionResource->Reventless.Adapter.outputToResource]
}

let make: Reventless.EventCollector_Adapter.channelMaker<callbackEvent, 'context> = (
  ~name,
  ~opts,
) => {
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
    Reventless.EventCollector_Adapter.resources: [queue->Util_SQS_FIFO.toResource],
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
