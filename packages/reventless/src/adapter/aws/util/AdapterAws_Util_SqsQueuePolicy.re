open Pulumi;

let allowResources:
  (~queue: PulumiAws.SQS.Queue.t, ~resources: array(Adapter.resource)) =>
  Output.t(string) =
  (~queue, ~resources) =>
    Output.all(
      [|queue##arn|]
      ->Array.append(resources |> Array.map(resource => resource##urn)),
    )
    ->Output.apply(arns => {
        let arnsList = arns |> Array.to_list;
        let queueArn = arnsList |> List.hd;
        let topicArns = arnsList |> List.tl;
        topicArns
        |> List.mapi((idx, topicArn) =>
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
        |> String.concat(",");
      });

let allowCloudWatchEvents =
  Output.make(
    {j|{
      "Effect": "Allow",
      "Principal": {
        "Service": ["events.amazonaws.com","sqs.amazonaws.com"]
      },
      "Action": "sqs:SendMessage",
      "Resource": "*"
    }|j},
  );

let make:
  (
    ~name: string,
    ~queue: PulumiAws.SQS.Queue.t,
    ~statements: list(Output.t(string)),
    ~opts: CustomResourceOptions.t=?,
    unit
  ) =>
  PulumiAws.SQS.QueuePolicy.t =
  (~name, ~queue, ~statements, ~opts=?, _) => {
    let policy =
      statements
      ->Array.of_list
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