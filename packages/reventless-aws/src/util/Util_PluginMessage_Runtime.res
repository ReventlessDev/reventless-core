let sendMessage = async (~channelId, ~messageBody) => {
  switch await AwsSdk.SQS.sendMessage(~queueId=channelId, ~messageBody) {
  | _ => ()
  | exception err => {
      Console.error2("Failed to send message to channel:", err)
      throw(err)
    }
  }
}
