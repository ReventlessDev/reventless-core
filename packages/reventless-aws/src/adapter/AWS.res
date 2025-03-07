let tags = (~name, componentType) =>
  [
    ("Name", name),
    ("Type", componentType->Reventless.ComponentType.toString),
    ("Environment", Pulumi.Pulumi.getStackName()),
    ("Plugin", Pulumi.Pulumi.getProjectName()),
  ]
  ->Js.Dict.fromArray
  ->Pulumi.Input.make

type service =
  | AppSync
  | IAM
  | CloudwatchEventRule
  | DynamoDb
  | DynamoDbStream
  | SQS
  | SQS_FIFO
  | SNS
  | SNS_FIFO
  | Kinesis
  | Lambda

let toString: service => string = service =>
  switch service {
  | DynamoDb => "DynamoDb"
  | DynamoDbStream => "DynamoDbStream"
  | SQS => "SQS"
  | SQS_FIFO => "SQS_FIFO"
  | SNS => "SNS"
  | SNS_FIFO => "SNS_FIFO"
  | Kinesis => "Kinesis"
  | Lambda => "Lambda"
  | AppSync => "AppSync"
  | IAM => "IAM"
  | CloudwatchEventRule => "CloudwatchEventRule"
  }

let toPrincipal: service => string = service =>
  switch service {
  | DynamoDb => "dynamodb.amazonaws.com"
  | DynamoDbStream => "dynamodb.amazonaws.com"
  | SQS => "sqs.amazonaws.com"
  | SQS_FIFO => "sqs.amazonaws.com"
  | SNS => "sns.amazonaws.com"
  | SNS_FIFO => "sns.amazonaws.com"
  | Kinesis => "kinesis.amazonaws.com"
  | Lambda => "lambda.amazonaws.com"
  | AppSync => "appsync.amazonaws.com"
  | IAM => "iam.amazonaws.com"
  | CloudwatchEventRule => "events.amazonaws.com"
  }

module DynamoDb = {
  let service = DynamoDb->toString
  let principal = DynamoDb->toPrincipal
}
module DynamoDbStream = {
  let service = DynamoDbStream->toString
  let principal = DynamoDbStream->toPrincipal
}
module Kinesis = {
  let service = Kinesis->toString
  let principal = Kinesis->toPrincipal
}
module Lambda = {
  let service = Lambda->toString
  let principal = Lambda->toPrincipal
}
module SNS = {
  let service = SNS->toString
  let principal = SNS->toPrincipal
}
module SNS_FIFO = {
  let service = SNS_FIFO->toString
  let principal = SNS_FIFO->toPrincipal
}
module SQS = {
  let service = SQS->toString
  let principal = SQS->toPrincipal
}
module SQS_FIFO = {
  let service = SQS_FIFO->toString
  let principal = SQS_FIFO->toPrincipal
}
module AppSync = {
  let service = AppSync->toString
  let principal = AppSync->toPrincipal
}
module IAM = {
  let service = IAM->toString
  let principal = IAM->toPrincipal
}
module CloudwatchEventRule = {
  let service = CloudwatchEventRule->toString
  let principal = CloudwatchEventRule->toPrincipal
}
