type callbackEvent = PulumiAws.Lambda.CallbackFunction.event
type channelParts = unit
type runtimeParts = Util.Lambda.runtimeParts

let subscribe = (
  ~name,
  ~eventTopics,
  ~channel as _,
  ~runtime: Reventless.Runtime.environment<runtimeParts>,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  let eventTopicResources =
    eventTopics
    ->(Js.Dict.map((eventTopic: Reventless.EventTopic.outputs) => eventTopic.resources, _))
    ->Reventless.Util.Adapter.partitionSupportedResources([AWS.DynamoDbStream.service])

  let _subscribeAndAttachPolicies = eventTopicResources->Pulumi.Output.apply(((
    dynamoDbStreamResources,
    errorResources,
  )) => {
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
              sid: "AllowLambdaToReadStream" ++ sourceName->String.split("-")->Array.getUnsafe(0),
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
        ~lambda=lambda->Pulumi.Output.make,
        ~targetName=name,
        ~sourceName,
        ~source=source->Reventless.AdapterDeploytime.unwrappedToResource,
        ~opts,
      )
    })

    let _attachLambdaPolicy = PulumiAws.IAM.RolePolicy.make(
      ~name,
      ~args={
        policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
          name ++ "LambdaPolicy",
          [PulumiAws.Lambda.defaultLoggingPolicyDocument]->Belt.Array.concat(
            streamSourcesWithPolicy->Belt.Array.map(((_, _, policyDocument)) => policyDocument),
          ),
        )->Pulumi.Output.asInput,
        role: lambdaRole.id->Pulumi.Output.asInput,
      },
      ~opts,
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

let make: Reventless.EventCollector_Adapter.channelMaker<
  callbackEvent,
  'context,
  unit,
  runtimeParts,
> = (~name as _, ~opts as _) => {
  let enqueueEventNotSupported = (delay, id, messageBody) =>
    // TODO: can we check this at deploy time ?
    Js.log4(__MODULE__ ++ " supports no enqueueEvent:", delay, id, messageBody)->Js.Promise.resolve

  {
    Reventless.EventCollector_Adapter.parts: (),
    resources: [],
    enqueueEvent: enqueueEventNotSupported->Pulumi.Output.make,
    subscribe,
    handleChannelEvent: handleEvents =>
      Pulumi.Output.make(EventCollectorChannel_SQS_Runtime.handleDynamoDbEvent(handleEvents, ...)),
  }
}
