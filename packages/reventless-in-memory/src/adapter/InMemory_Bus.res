// Shared in-memory event and command bus.
// Each Platform.Make() creates a fresh isolated bus — no global state, no test interference.

module type T = {
  // Event fan-out: aggregate EventTopic → read model EventCollector
  let publishEvent: (string, string, Reventless.Message.meta, JSON.t) => promise<unit>
  let subscribeToEvents: (string, (string, Reventless.Message.meta, JSON.t) => promise<unit>) => unit

  // Command dispatch: CommandTopic → aggregate command handler
  // Dispatches a single encoded command JSON {reference, commandJson}
  let dispatchCommand: (string, JSON.t) => promise<unit>
  let registerCommandHandler: (string, (JSON.t, unit) => promise<unit>) => unit

  let reset: unit => unit
}

module Make = (): T => {
  let eventSubscribers: ref<
    dict<array<(string, Reventless.Message.meta, JSON.t) => promise<unit>>>,
  > = ref(Dict.make())
  let commandHandlers: ref<dict<(JSON.t, unit) => promise<unit>>> = ref(Dict.make())

  let publishEvent = async (topicName, service, meta, json) => {
    let subscribers = eventSubscribers.contents->Dict.get(topicName)->Option.getOr([])
    let _ = await subscribers->Array.map(sub => sub(service, meta, json))->Promise.all
  }

  let subscribeToEvents = (topicName, handler) => {
    let existing = eventSubscribers.contents->Dict.get(topicName)->Option.getOr([])
    eventSubscribers.contents->Dict.set(topicName, existing->Array.concat([handler]))
  }

  let dispatchCommand = async (channelName, json) => {
    switch commandHandlers.contents->Dict.get(channelName) {
    | Some(handler) => await handler(json, ())
    | None => Console.log2("InMemory_Bus: no command handler for channel", channelName)
    }
  }

  let registerCommandHandler = (channelName, handler) => {
    commandHandlers.contents->Dict.set(channelName, handler)
  }

  let reset = () => {
    eventSubscribers := Dict.make()
    commandHandlers := Dict.make()
  }
}
