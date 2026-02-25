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

  // QueryDb registry: read model name → storage ops and scan function
  // Populated by QueryDbStorage_InMemory.Make(Bus) during component construction.
  let registerQueryDb: (string, Reventless.QueryDb_Adapter.operations) => unit
  let getQueryDb: string => option<Reventless.QueryDb_Adapter.operations>
  let registerQueryDbScan: (string, unit => array<JSON.t>) => unit
  let getQueryDbScan: string => option<unit => array<JSON.t>>

  let reset: unit => unit
}

module Make = (): T => {
  let eventSubscribers: ref<
    dict<array<(string, Reventless.Message.meta, JSON.t) => promise<unit>>>,
  > = ref(Dict.make())
  let commandHandlers: ref<dict<(JSON.t, unit) => promise<unit>>> = ref(Dict.make())
  let queryDbRegistry: ref<dict<Reventless.QueryDb_Adapter.operations>> = ref(Dict.make())
  let queryDbScanRegistry: ref<dict<unit => array<JSON.t>>> = ref(Dict.make())

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

  let registerQueryDb = (name, ops) => queryDbRegistry.contents->Dict.set(name, ops)
  let getQueryDb = name => queryDbRegistry.contents->Dict.get(name)
  let registerQueryDbScan = (name, scan) => queryDbScanRegistry.contents->Dict.set(name, scan)
  let getQueryDbScan = name => queryDbScanRegistry.contents->Dict.get(name)

  let reset = () => {
    eventSubscribers := Dict.make()
    commandHandlers := Dict.make()
    queryDbRegistry := Dict.make()
    queryDbScanRegistry := Dict.make()
  }
}
