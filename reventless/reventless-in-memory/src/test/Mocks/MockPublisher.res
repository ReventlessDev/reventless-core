// Mock EventTopic publisher that captures publishJson calls for assertion.
// Returns a record with publishJson (usable as EventTopic_Adapter publisher input),
// publishedMessages ref, and reset().

type publishedMessage = {
  service: string,
  meta: Reventless.Message.meta,
  json: JSON.t,
}

type t = {
  publishJson: Reventless.EventTopic.publishJson,
  publishedMessages: ref<array<publishedMessage>>,
  reset: unit => unit,
}

let make = () => {
  let publishedMessages: ref<array<publishedMessage>> = ref([])

  let publishJson: Reventless.EventTopic.publishJson = async (service, meta, json) => {
    publishedMessages := publishedMessages.contents->Array.concat([{service, meta, json}])
  }

  let reset = () => {
    publishedMessages := []
  }

  {publishJson, publishedMessages, reset}
}
