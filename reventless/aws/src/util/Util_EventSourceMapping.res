open PulumiAws

// `~tags` is required rather than optional: an EventSourceMapping is created by
// several unrelated adapters, and an optional argument is exactly how the last
// coverage sweep left these bare. Making the caller name the owning piece is the
// regression guard — the same reasoning as `makeFromCodeAsset`'s `~componentKind`.
let subscribe = (
  ~batchSize=?,
  ~lambda: Pulumi.Output.t<PulumiAws.Lambda.Function.t>,
  ~targetName,
  ~sourceName,
  ~source: ReventlessInfra.Adapter.resource,
  ~tags: Pulumi.Input.t<Aws.tags>,
  ~opts,
) =>
  EventSourceMapping.make(
    ~name=sourceName->ReventlessCore.Util.baseName ++ ("2" ++ targetName),
    ~args={
      EventSourceMapping.functionName: lambda
      ->Pulumi.Output.flatMap(lambda => lambda.arn)
      ->Pulumi.Output.asInput,
      eventSourceArn: source.urn->Pulumi.Output.asInput,
      startingPosition: LATEST,
      ?batchSize,
      tags,
    },
    ~opts=Some(opts),
  )

let subscribeSqs = (
  ~lambda: Pulumi.Output.t<PulumiAws.Lambda.Function.t>,
  ~name,
  ~queue: PulumiAws.SQS.Queue.t,
  ~batchSize=?,
  ~tags: Pulumi.Input.t<Aws.tags>,
  ~opts,
) => {
  let esm = EventSourceMapping.make(
    ~name,
    ~args={
      EventSourceMapping.functionName: lambda
      ->Pulumi.Output.flatMap(lambda => lambda.arn)
      ->Pulumi.Output.asInput,
      eventSourceArn: queue.arn->Pulumi.Output.asInput,
      ?batchSize,
      tags,
    },
    ~opts=Some(opts),
  )
  ReventlessInfra.Adapter.make(
    ~name=esm.id,
    ~id=esm.id,
    ~urn=esm.arn,
    ~service=esm.id->Pulumi.Output.apply(_ => AWS.SQS.service),
    ~resourceType="aws:lambda:EventSourceMapping"->Pulumi.Output.make,
  )
}
