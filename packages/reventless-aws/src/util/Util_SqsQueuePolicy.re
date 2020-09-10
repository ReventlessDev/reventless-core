open Pulumi;

let allowResources:
  (
    ~queue: PulumiAws.SQS.Queue.t,
    ~resources: array(Output.t(Reventless.Adapter.resource))
  ) =>
  Output.t(string) =
  (~queue, ~resources) =>
    Output.all2((
      queue##arn,
      resources
      ->Output.all
      ->Output.flatMap(resources =>
          resources->Belt.Array.map(resource => resource##urn)->Output.all
        ),
    ))
    ->Output.apply(((queueArn, topicArns)) =>
        topicArns
        ->Belt.Array.mapWithIndex((idx, topicArn) =>
            {j|{
              "Sid": "$idx",
              "Effect": "Allow",
              "Principal": "*",
              "Action": "sqs:SendMessage",
              "Resource": "$queueArn",
              "Condition": {
                "ArnEquals": {
                  "aws:SourceArn": "$topicArn"
                }
              }
            }|j}
          )
        ->Js.String.concatMany(",")
      );

let allowCloudWatchEvents =
  {j|{
      "Effect": "Allow",
      "Principal": {
        "Service": ["events.amazonaws.com","sqs.amazonaws.com"]
      },
      "Action": "sqs:SendMessage",
      "Resource": "*"
    }|j}
  ->Output.make;

let make:
  (
    ~name: string,
    ~queue: PulumiAws.SQS.Queue.t,
    ~statements: array(Output.t(string)),
    ~opts: CustomResourceOptions.t=?,
    unit
  ) =>
  PulumiAws.SQS.QueuePolicy.t =
  (~name, ~queue, ~statements, ~opts=?, _) => {
    let policy =
      statements
      ->Output.all
      ->Output.apply(statementStrs => {
          let statementStr =
            statementStrs->Array.to_list |> String.concat(",");
          {j|{
              "Version": "2012-10-17",
              "Id": "$name",
              "Statement": [
                $statementStr
              ]
            }|j};
        })
      ->Output.asInput;

    PulumiAws.SQS.QueuePolicy.make(
      ~name,
      ~args=
        PulumiAws.SQS.QueuePolicy.Args.make(
          ~policy,
          ~queueUrl=queue##id->Output.asInput,
        ),
      ~opts,
    );
  };
