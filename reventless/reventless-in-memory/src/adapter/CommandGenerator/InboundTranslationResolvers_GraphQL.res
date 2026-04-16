// GraphQL mutation resolvers for in-memory InboundTranslationSlices.
// Registers one GraphQL mutation field per InboundTranslationSlice.
// Each resolver calls `receive(argsJson)` directly — the InboundTranslationSlice
// handles parsing, validation, translation, and command publishing internally.

@@warning("-44")
open ReventlessCore

// Mutable registry: fieldName → receive function.
// Pre-populated synchronously in Phase 1 via a queuing forwarder so callers
// (e.g. PlatformInspector's onPlatformDeployedHook) can invoke receive before
// Phase 2 bindReceive runs. Calls park in a Promise queue and drain once bound.
let receiveRegistry: dict<JSON.t => promise<result<array<string>, string>>> = Dict.make()

type pendingCall = {
  inputJson: JSON.t,
  resolve: result<array<string>, string> => unit,
}

// Per-field pending-call queues — drained when bindReceive fires.
let pendingQueueRegistry: dict<ref<array<pendingCall>>> = Dict.make()

// Phase 1: Register SDL + resolver stub synchronously (before server starts).
// Also pre-registers a queuing forwarder in receiveRegistry so callers can
// invoke receive immediately; calls are parked until bindReceive drains them.
let register = (~fieldName: string, ~externalInputSchema: S.t<unknown>, ~server: GraphQL_ServerInstance.t) => {
  let sdlFields = switch GraphQL_FragmentGenerator.deriveMutationFieldFromObject(
    ~fieldName,
    ~collectedTypes=[],
    ~seenTypes=Set.make(),
    externalInputSchema,
  ) {
  | Some(field) => [field]
  | None => [`  ${fieldName}: String!`]
  }

  // Queue of pending calls when receive is not yet bound.
  let pendingQueue: ref<array<pendingCall>> = ref([])
  pendingQueueRegistry->Dict.set(fieldName, pendingQueue)

  // Queuing forwarder: parks calls until bindReceive populates receiveRegistry.
  let queuingReceive = (inputJson: JSON.t) =>
    Promise.make((resolve, _reject) => {
      pendingQueue.contents->Array.push({inputJson, resolve})
    })
  receiveRegistry->Dict.set(fieldName, queuingReceive)

  let resolver: GraphQL_ServerInstance.resolverFn = async (_root, args, _ctx) => {
    let inputJson: JSON.t = args->Obj.magic
    let receive = receiveRegistry->Dict.getUnsafe(fieldName)
    let result = await receive(inputJson)
    switch result {
    | Ok(targetIds) => targetIds->Array.map(JSON.Encode.string)->JSON.Encode.array
    | Error(msg) => msg->JSON.Encode.string
    }
  }

  let resolvers = Dict.make()
  resolvers->Dict.set(fieldName, resolver)
  server.registerMutations(~sdlFields, ~resolvers)
}

// Phase 2: Bind the real receive function once Output.apply resolves.
// Replaces the queuing forwarder in receiveRegistry and drains pending calls.
let bindReceive = (~fieldName: string, ~receive: JSON.t => promise<result<array<string>, string>>) => {
  receiveRegistry->Dict.set(fieldName, receive)
  switch pendingQueueRegistry->Dict.get(fieldName) {
  | Some(pendingQueue) =>
    let pending = pendingQueue.contents
    pendingQueue.contents = []
    pending->Array.forEach(({inputJson, resolve}) => {
      let _ = receive(inputJson)->Promise.thenResolve(result => resolve(result))
    })
  | None => ()
  }
}
