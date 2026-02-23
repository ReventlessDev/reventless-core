let subscribe = async (~channelId, ~topicId) => {
  switch await AwsSdk.SNS.subscribeQueueToTopic(channelId, topicId) {
  | _ => ()
  | exception JsExn(e) => {
      Console.error2("Failed to subscribe channel to topic:", e)
      throw(JsExn(e))
    }
  }
}

let unsubscribe = async (~channelId, ~topicId) => {
  switch await AwsSdk.SNS.unsubscribeQueueFromTopic(channelId, topicId) {
  | _ => ()
  | exception JsExn(e) => {
      Console.error2("Failed to unsubscribe channel from topic:", e)
      throw(JsExn(e))
    }
  }
}
