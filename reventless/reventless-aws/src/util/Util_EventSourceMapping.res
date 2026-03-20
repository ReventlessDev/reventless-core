open PulumiAws

let subscribe = (
  ~batchSize=?,
  ~lambda: Pulumi.Output.t<PulumiAws.Lambda.Function.t>,
  ~targetName,
  ~sourceName,
  ~source: ReventlessInfra.Adapter.resource,
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
    },
    ~opts=Some(opts),
  )

let subscribeSqs = (
  ~lambda: Pulumi.Output.t<PulumiAws.Lambda.Function.t>,
  ~name,
  ~queue: PulumiAws.SQS.Queue.t,
  ~opts,
) => {
  let esm = EventSourceMapping.make(
    ~name,
    ~args={
      EventSourceMapping.functionName: lambda
      ->Pulumi.Output.flatMap(lambda => lambda.arn)
      ->Pulumi.Output.asInput,
      eventSourceArn: queue.arn->Pulumi.Output.asInput,
    },
    ~opts=Some(opts),
  )
  (
    {
      ReventlessInfra.Adapter.service: esm.id->Pulumi.Output.apply(_ => AWS.SQS.service),
      name: esm.id,
      id: esm.id,
      urn: esm.arn,
      info: esm.id->Pulumi.Output.apply(_ => ""),
    }: ReventlessInfra.Adapter.resource
  )
}
