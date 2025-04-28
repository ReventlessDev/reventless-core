type bucket<'bucketParts> = {resources: array<ReventlessSpec.Adapter.resource>, parts: 'bucketParts}

type connect<'bucketParts, 'runtimeParts> = (
  ~name: string,
  ~bucket: bucket<'bucketParts>,
  ~runtime: Runtime.environment<'runtimeParts>,
  ~opts: Pulumi.ComponentResource.options,
) => unit // array<ReventlessSpec.Adapter.resource>

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
  let makeHandler: Task.bucketCallback => Pulumi.Output.t<
    Runtime.eventHandler<callbackEvent, context, unit>,
  >
  let make: bucketMaker<bucketParts>
}
