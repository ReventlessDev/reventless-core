open PulumiAws

let make: Reventless.Runtime.environmentMaker = (~name, ~channelResources, ~handleJsons, ~opts) => {
  let lambdaResource =
    channelResources
    ->Util.SQS.findResource
    ->Util.SQS.fromResource
    ->Pulumi.Output.flatMap(queue =>
      queue
      ->Util_SQS.toRuntimeQueueOutput
      ->Pulumi.Output.apply(runtimeQueue => {
        let handler = {
          Lambda.CallbackFunction.make(
            ~name,
            ~args=Lambda.CallbackFunction.Args.make(
              ~callback=CommandTopicChannel_SQS_Runtime.handleQueueEvent(
                handleJsons,
                runtimeQueue,
                ...
              ),
              ~policies=Lambda.Policy.defaultPolicies,
              ~memorySize=1024->Pulumi.Input.make,
              ~timeout=30->Pulumi.Input.make,
              ~tags=AWS.tags(~name, Reventless.CommandTopic.componentType),
            ),
            ~opts,
          )
        }

        let _queueSubscription = queue->SQS.Queue.onEvent(~name, ~handler, ~opts)
        handler->Util_Lambda.toResource
      })
    )
    ->Reventless.Adapter.outputToResource

  {
    resources: [lambdaResource],
  }
}
