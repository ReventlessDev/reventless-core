/***  @aws-sdk/client-sns
  see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/sns/
*/
type client

type options = {
  maxAttempts?: int,
  region?: string,
  requestHandler?: NodeHttpHandler.t,
}

module Raw = {
  @module("@aws-sdk/client-sns") @new
  external client: (~options: options, unit) => client = "SNSClient"
}

let clientInstance = ref(None)

// TODO: instead of mutating snsInstance, use lazy
let client = () =>
  switch clientInstance.contents {
  | None =>
    let client = Raw.client(
      ~options={
        maxAttempts: 5,
        requestHandler: NodeHttpHandler.make({
          connectionTimeout: 5000,
          requestTimeout: 5000,
        }),
      },
      (),
    )
    clientInstance := Some(client)
    client
  | Some(client) => client
  }

module PublishCommand = {
  type input = {
    @as("Message") message: string,
    @as("MessageStructure") messageStructure?: string,
    @as("PhoneNumber") phoneNumber?: string,
    @as("TargetArn") targetArn?: string,
    @as("TopicArn") topicArn?: string,
    @as("Subject") subject?: string,
    @as("MessageDeduplicationId") messageDeduplicationId?: string,
    @as("MessageGroupId") messageGroupId?: string,
  }

  type output = {@as("MessageId") messageId: string}

  type t
  @new @module("@aws-sdk/client-sns")
  external make: input => t = "PublishCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

let publish = (~topicArn, ~messageGroupId=?, message) =>
  PublishCommand.send(
    PublishCommand.make({
      topicArn,
      messageGroupId: ?(messageGroupId->Option.map(id => id->String.replaceRegExp(/ /g, ""))),
      message,
    }),
  )

module SubscribeCommand = {
  type redrivePolicy = {deadLetterTargetArn?: string}

  type attributes = {
    @as("DeliveryPolicy") deliveryPolicy?: string,
    @as("FilterPolicy") filterPolicy?: string,
    @as("RawMessageDelivery") rawMessageDelivery?: string,
    @as("RedrivePolicy") redrivePolicy?: redrivePolicy,
  }

  type t

  type input = {
    @as("TopicArn") topicArn: string,
    @as("Protocol")
    protocol: [
      | #http
      | #https
      | #email
      | #"email-json"
      | #sms
      | #sqs
      | #application
      | #lambda
    ],
    @as("Endpoint") endpoint: string,
    @as("Attributes") attributes?: attributes,
    @as("ReturnSubscriptionArn") returnSubscriptionArn?: bool,
  }

  type output = {
    @as("SubscriptionArn")
    subscriptionArn: string /* either the actual arn or "pending confirmation" */,
  }

  let getSubscriptionArn: output => result<string, string> = response => {
    let subscriptionArn = response.subscriptionArn
    if subscriptionArn == "pending confirmation" {
      Error(subscriptionArn)
    } else {
      Ok(subscriptionArn)
    }
  }

  @new @module("@aws-sdk/client-sns")
  external make: input => /* default: false */ t = "SubscribeCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module UnsubscribeCommand = {
  type t

  type input = {@as("SubscriptionArn") subscriptionArn: string}

  type output = {.}

  @new @module("@aws-sdk/client-sns") external make: input => t = "UnsubscribeCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module ListSubscriptionsByTopicCommand = {
  type t

  type input = {
    @as("TopicArn") topicArn: string,
    @as("NextToken") nextToken?: string,
  }

  type subscription = {
    @as("SubscriptionArn") subscriptionArn: string,
    @as("Owner") owner: string,
    @as("TopicArn") topicArn: string,
    @as("Protocol") protocol: string,
    @as("Endpoint") endpoint: string,
  }

  type output = {
    @as("Subscriptions") subscriptions: array<subscription>,
    @as("NextToken") nextToken: string,
  }

  @new @module("@aws-sdk/client-sns")
  external make: input => t = "ListSubscriptionsByTopicCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

let findSubscription = async (queueArn, topicArn) => {
  let response = await ListSubscriptionsByTopicCommand.send(
    ListSubscriptionsByTopicCommand.make({topicArn: topicArn}),
  ) // TODO: handle paging of subscriptions
  response.subscriptions->Array.find(subscription => subscription.endpoint == queueArn)
}

let subscribeQueueToTopic = async (queueArn, topicArn) =>
  // TODO: add dlq in RedrivePolicy
  switch await findSubscription(queueArn, topicArn) {
  | None =>
    let subscriptionResponse = await SubscribeCommand.send(
      SubscribeCommand.make({
        topicArn,
        protocol: #sqs,
        endpoint: queueArn,
        attributes: {
          rawMessageDelivery: "true",
        },
      }),
    )
    Console.log2("subscribed:", subscriptionResponse.subscriptionArn)

  | Some(subscription) =>
    Console.log2("re-using existing subscription:", subscription.subscriptionArn)
  }

let unsubscribeQueueFromTopic = async (queueArn, topicArn) =>
  switch await findSubscription(queueArn, topicArn) {
  | Some(subscription) =>
    let _unsubscribeResponse = await UnsubscribeCommand.send(
      UnsubscribeCommand.make({subscriptionArn: subscription.subscriptionArn}),
    )
    let _ = Console.log2("unsubscribed:", subscription.subscriptionArn)
  | None => Console.log2("there is no subscription for queue:", queueArn)
  }
