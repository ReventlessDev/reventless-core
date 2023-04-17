open PulumiAws

@ocaml.doc(" TODO: handle other EventSources than Stream ")
let subscribe = (~batchSize=?, ~lambda, ~targetName, ~sourceName, ~source, ~opts, ()) =>
  EventSourceMapping.make(
    ~name=sourceName ++ ("2" ++ targetName),
    ~args=EventSourceMapping.Args.make(
      ~functionName=lambda->Pulumi.Output.flatMap(lambda => lambda["arn"])->Pulumi.Output.asInput,
      ~eventSourceArn=source["urn"]->Pulumi.Output.asInput,
      ~startingPosition=#LATEST,
      ~batchSize?,
      (),
    ),
    ~opts=Some(opts),
  )
