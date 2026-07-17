type bucket<'bucketParts> = {resources: array<ReventlessInfra.Adapter.resource>, parts: 'bucketParts}

type connect<'bucketParts, 'runtimeParts> = (
  ~name: string,
  ~bucket: bucket<'bucketParts>,
  ~bucketMode: Task.bucketMode,
  ~commandTopics: Pulumi.Output.t<CommandTopic.allOutputs>,
  ~runtime: Runtime.environment<'runtimeParts>,
  ~opts: Pulumi.ComponentResource.options,
) => unit // array<ReventlessInfra.Adapter.resource>

type bucketMaker<'parts> = (
  ~name: string,
  ~opts: Pulumi.ComponentResource.options,
) => bucket<'parts>

module type Bucket = {
  type runtimeParts
  type callbackEvent
  type context
  type bucketParts

  let connect: connect<bucketParts, runtimeParts>
  let makeHandler: Task.bucketCallback => Runtime.eventHandler<
    callbackEvent,
    context,
    array<Task.taskAction>,
  >

  let make: bucketMaker<bucketParts>
}
