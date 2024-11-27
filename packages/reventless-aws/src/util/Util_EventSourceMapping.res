open PulumiAws

/** TODO: handle other EventSources than Stream */
let subscribe = (
  ~batchSize=?,
  ~lambda: Pulumi.Output.t<PulumiAws.Lambda.CallbackFunction.t>,
  ~targetName,
  ~sourceName,
  ~source: ReventlessSpec.Adapter.resource,
  ~opts,
) =>
  EventSourceMapping.make(
    ~name=sourceName ++ ("2" ++ targetName),
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
