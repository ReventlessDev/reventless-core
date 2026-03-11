let publish = (~topicArn, ~messageGroupId=?, message) =>
  SNS.PublishCommand.send(
    SNS.PublishCommand.make({
      topicArn,
      messageGroupId: ?(messageGroupId->Option.map(id => id->String.replaceRegExp(/ /g, ""))),
      message,
    }),
  )

let findSubscription = async (queueArn, topicArn) => {
  let response = await SNS.ListSubscriptionsByTopicCommand.send(
    SNS.ListSubscriptionsByTopicCommand.make({topicArn: topicArn}),
  ) // TODO: handle paging of subscriptions
  response.subscriptions->Array.find(subscription => subscription.endpoint == queueArn)
}

let subscribeQueueToTopic = async (queueArn, topicArn) =>
  // TODO: add dlq in RedrivePolicy
  switch await findSubscription(queueArn, topicArn) {
  | None =>
    let subscriptionResponse = await SNS.SubscribeCommand.send(
      SNS.SubscribeCommand.make({
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
    let _unsubscribeResponse = await SNS.UnsubscribeCommand.send(
      SNS.UnsubscribeCommand.make({subscriptionArn: subscription.subscriptionArn}),
    )
    let _ = Console.log2("unsubscribed:", subscription.subscriptionArn)
  | None => Console.log2("there is no subscription for queue:", queueArn)
  }
