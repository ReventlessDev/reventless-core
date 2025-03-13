type callbackEvent = PulumiAws.Lambda.CallbackFunction.event

let subscribe = (
  ~name,
  ~eventTopics,
  ~channel as _,
  ~runtime: Reventless.Runtime.environment,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let handler =
    runtime.resources
    ->Util.Lambda.findResource
    ->Util.Lambda.fromResource

  let handlerRole = runtime.resources->Util.IAM_Role.findResource->Util.IAM_Role.fromResource

  let eventTopicResources =
    eventTopics
    ->(Js.Dict.map((eventTopic: Reventless.EventTopic.outputs) => eventTopic.resources, _))
    ->Reventless.Util.Adapter.partitionSupportedResources([AWS.DynamoDbStream.service])

  let _subscribeAndAttachPolicies =
    (eventTopicResources, handler, handlerRole)
    ->Pulumi.Output.all3
    ->Pulumi.Output.apply((((dynamoDbStreamResources, errorResources), handler, handlerRole)) => {
      let streamSourceWithPolicy = dynamoDbStreamResources->Belt.Array.map(((sourceName, sources)) => {
        let source = sources->Array.getUnsafe(0)->Reventless.AdapterDeploytime.unwrappedToResource
        source.urn->Pulumi.Output.apply(
          sourceUrn => {
            open PulumiAws.PolicyDocument
            {
              Util_DynamoDbStream.sourceName,
              source,
              lambdaPolicyDocument: PulumiAws.PolicyDocument.make(
                ~statements=[
                  {
                    sid: "AllowLambdaToReadStream" ++ sourceName,
                    effect: Allow,
                    actions: Actions([
                      "dynamodb:DescribeStream",
                      "dynamodb:GetRecords",
                      "dynamodb:GetShardIterator",
                      "dynamodb:ListStreams",
                    ]),
                    resources: Resource(sourceUrn),
                  },
                ],
              ),
            }
          },
        )
      })

      let _subscribeEventStreams = streamSourceWithPolicy->Belt.Array.map(dynamoDbStreamData => {
        dynamoDbStreamData->Pulumi.Output.apply(
          streamData => {
            Util_EventSourceMapping.subscribe(
              ~batchSize=25,
              ~lambda=handler->Pulumi.Output.make,
              ~targetName=name,
              ~sourceName=streamData.sourceName,
              ~source=streamData.source,
              ~opts,
            )
          },
        )
      })

      let lambdaPolicy = PulumiAws.IAM.Policy.make(
        ~name,
        ~args={
          policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
            ~policyDocuments=Belt.Array.concat(
              [PulumiAws.Lambda.defaultLoggingPolicyDocument],
              streamSourceWithPolicy
              ->Belt.Array.map(output => output->Pulumi.Output.unwrap)
              ->Belt.Array.map(resource => resource.lambdaPolicyDocument),
            ),
          )->Pulumi.Output.asInput,
        },
        ~opts,
      )

      let _attachLambdaPolicy = PulumiAws.IAM.RolePolicyAttachment.make(
        ~name,
        ~args={
          policyArn: lambdaPolicy.arn->Pulumi.Output.asInput,
          role: handlerRole.arn->Pulumi.Output.asInput,
        },
        ~opts=Some(opts),
      )

    if errorResources->Belt.Array.length > 0 {
      let eventTopicNames = errorResources->Js.Array2.joinWith(",")
      Js.Exn.raiseError(
        __MODULE__ ++ `.subscribe: cannot connect to EventTopic(s) ${eventTopicNames}`,
      )
    }
  })

  []
}

let make: Reventless.EventCollector_Adapter.channelMaker<callbackEvent, 'context> = (
  ~name as _,
  ~opts as _,
) => {
  let enqueueEventNotSupported = (delay, id, messageBody) =>
    // TODO: can we check this at deploy time ?
    Js.log4(__MODULE__ ++ " supports no enqueueEvent:", delay, id, messageBody)->Js.Promise.resolve

  {
    Reventless.EventCollector_Adapter.resources: [],
    enqueueEvent: enqueueEventNotSupported->Pulumi.Output.make,
    subscribe,
    handleChannelEvent: handleEvents =>
      Pulumi.Output.make(EventCollectorChannel_SQS_Runtime.handleDynamoDbEvent(handleEvents, ...)),
  }
}
