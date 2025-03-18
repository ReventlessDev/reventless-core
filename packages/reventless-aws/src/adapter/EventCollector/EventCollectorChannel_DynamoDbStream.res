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
      let streamSourcesWithPolicy = dynamoDbStreamResources->Belt.Array.map(((
        sourceName,
        sources,
      )) => {
        let source = sources->Array.getUnsafe(0)
        open PulumiAws.PolicyDocument

        (
          sourceName,
          source,
          PulumiAws.PolicyDocument.make(
            ~id=name ++ "Policy",
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
                resources: Resource(source.urn),
              },
            ],
          ),
        )
      })

      let _subscribeEventStreams = streamSourcesWithPolicy->Belt.Array.map(((
        sourceName,
        source,
        _policy,
      )) => {
        Util_EventSourceMapping.subscribe(
          ~batchSize=25,
          ~lambda=handler->Pulumi.Output.make,
          ~targetName=name,
          ~sourceName,
          ~source=source->Reventless.AdapterDeploytime.unwrappedToResource,
          ~opts,
        )
      })

      let lambdaPolicy = PulumiAws.IAM.Policy.make(
        ~name,
        ~args={
          policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
            name ++ "LambdaPolicy",
            [PulumiAws.Lambda.defaultLoggingPolicyDocument]->Belt.Array.concat(
              streamSourcesWithPolicy->Belt.Array.map(((_, _, policyDocument)) => policyDocument),
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
