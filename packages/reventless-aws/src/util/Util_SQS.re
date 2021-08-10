let service = "SQS";

let toResource = (queue: PulumiAws.SQS.Queue.t) =>
  Reventless.Adapter.resource(
    ~service,
    ~name=queue##name,
    ~id=queue##id,
    ~urn=queue##arn,
    ~info=queue##name->Pulumi.Output.apply(_ => ""),
  );

// Example ARN: arn:aws:sqs:eu-west-1:000000000000:MarketplaceServiceExtensionPointCommandTopic-0101023
let arn2Account = arn =>
  switch (arn->Js.String2.split(":")) {
  | [|_, _, _, _, account, _|] => account
  | _ => ""
  };
