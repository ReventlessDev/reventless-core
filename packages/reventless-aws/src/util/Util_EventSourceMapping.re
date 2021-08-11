open PulumiAws;

let subscribe = (lambda, targetName, opts, (_, (sourceName, topic))) =>
  EventSourceMapping.make(
    ~name=sourceName ++ "2" ++ targetName,
    ~args=
      EventSourceMapping.Args.make(
        ~functionName=
          lambda
          ->Pulumi.Output.flatMap(lambda => lambda##arn)
          ->Pulumi.Output.asInput,
        ~eventSourceArn=topic##urn->Pulumi.Output.asInput,
        ~startingPosition=`TRIM_HORIZON,
        (),
      ),
    ~opts=Some(opts),
  );
