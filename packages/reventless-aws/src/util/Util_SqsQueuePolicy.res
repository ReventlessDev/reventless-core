open Pulumi

let allowAllResourcesSendMessage = queue =>
  queue["arn"]->Output.apply(queueArn => {
    let account = queueArn->Util_SQS.arn2Account
    `
        {
          "Sid": "allowAllResourcesSendMessage",
          "Effect": "Allow",
          "Principal": "*",
          "Action": "sqs:SendMessage",
          "Resource": "${queueArn}",
          "Condition": {
            "StringEquals": {
              "aws:SourceAccount": "${account}"
            }
          }
        }
      `
  })
let allowAllSnsTopicsSendMessage = queue =>
  queue["arn"]->Output.apply(queueArn => {
    let account = queueArn->Util_SQS.arn2Account
    `
        {
          "Sid": "allowAllSnsTopicsSendMessage",
          "Effect": "Allow",
          "Principal": {
              "Service": [
                "sns.amazonaws.com"
              ]
            },
          "Action": "sqs:SendMessage",
          "Resource": "${queueArn}",
          "Condition": {
            "StringEquals": {
              "aws:SourceAccount": "${account}"
            }
          }
        }
      `
  })
let allowResourceSendMessage = (queueArn, idx, sourceArn) =>
  `
  {
    "Sid": "${idx->Belt.Int.toString}",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "sqs:SendMessage",
    "Resource": "${queueArn}",
    "Condition": {
      "ArnEquals": {
        "aws:SourceArn": "${sourceArn}"
      }
    }
  }
`

let allowResourcesSendMessage: (
  ~queue: PulumiAws.SQS.Queue.t,
  ~resources: array<Output.t<ReventlessSpec.Adapter.resource>>,
) => Output.t<string> = (~queue, ~resources) =>
  Output.all2((
    queue["arn"],
    resources
    ->Output.all
    ->Output.flatMap(resources =>
      resources->Belt.Array.map(resource => resource["urn"])->Output.all
    ),
  ))->Output.apply(((queueArn, topicArns)) =>
    topicArns->Belt.Array.mapWithIndex(allowResourceSendMessage(queueArn))->Js.Array2.joinWith(",")
  )

let allowCloudWatchEvents = `{
      "Effect": "Allow",
      "Principal": {
        "Service": ["events.amazonaws.com","sqs.amazonaws.com"]
      },
      "Action": "sqs:SendMessage",
      "Resource": "*"
    }`->Output.make

let make: (
  ~name: string,
  ~queue: PulumiAws.SQS.Queue.t,
  ~statements: array<Output.t<string>>,
  ~opts: CustomResourceOptions.t=?,
  unit,
) => PulumiAws.SQS.QueuePolicy.t = (~name, ~queue, ~statements, ~opts=?, _) => {
  let policy =
    statements
    ->Output.all
    ->Output.apply(statementStrs => {
      let statementStr = statementStrs->Js.Array2.joinWith(",")
      `{
              "Version": "2012-10-17",
              "Id": "${name}",
              "Statement": [
                ${statementStr}
              ]
            }`
    })
    ->Output.asInput

  PulumiAws.SQS.QueuePolicy.make(
    ~name,
    ~args=PulumiAws.SQS.QueuePolicy.Args.make(~policy, ~queueUrl=queue["id"]->Output.asInput),
    ~opts,
  )
}
