open PulumiAws;

/** TODO: handle other EventSources than Stream */
let subscribe = (~lambda, ~targetName, ~sourceName, ~source, ~opts) => {
  let eventSourceMapping =
    EventSourceMapping.make(
      ~name=sourceName ++ "2" ++ targetName,
      ~args=
        EventSourceMapping.Args.make(
          ~functionName=
            lambda
            ->Pulumi.Output.flatMap(lambda => lambda##arn)
            ->Pulumi.Output.asInput,
          ~eventSourceArn=source##urn->Pulumi.Output.asInput,
          ~startingPosition=`LATEST,
          (),
        ),
      ~opts=Some(opts),
    );
  let result = eventSourceMapping->Js.Json.stringifyAny;
  Js.log(
    __MODULE__
    ++ {j|.subscribe: targetName: $targetName, sourceName: $sourceName, result: $result|j},
  );
  eventSourceMapping;
};
