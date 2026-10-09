// GraphQL mutation resolvers for in-memory InboundTranslationSlices: one field per
// slice, gated by the door's rule and handing the caller on to `receive`.

@@warning("-44")
open ReventlessCore

type receive = (
  JSON.t,
  ~caller: Reventless.Identity.t=?,
) => promise<ReventlessInfra.InboundTranslationSlice.receiveResult>

// fieldName → receive. Pre-populated with a queuing forwarder so a call made
// before `bindReceive` parks until it runs.
let receiveRegistry: dict<receive> = Dict.make()

type pendingCall = {
  inputJson: JSON.t,
  caller: option<Reventless.Identity.t>,
  resolve: ReventlessInfra.InboundTranslationSlice.receiveResult => unit,
}

let pendingQueueRegistry: dict<ref<array<pendingCall>>> = Dict.make()

// Phase 1: register SDL + resolver stub synchronously (before server starts).
// `permission` is the door's rule; without one the field admits nobody.
let register = (
  ~fieldName: string,
  ~externalInputSchema: S.t<unknown>,
  ~permission: option<Reventless.Authorization.permission>=?,
  ~server: ReventlessGraphqlServer.GraphQL_ServerInstance.t,
) => {
  // Registered here, so a plugin whose only mutation is inbound has its result union.
  CommandGeneratorResolvers_GraphQL.ensureCommandResultTypes(server)

  let sdlFields = switch GraphQL_FragmentGenerator.deriveMutationFieldFromObject(
    ~fieldName,
    ~collectedTypes=[],
    ~seenTypes=Set.make(),
    externalInputSchema,
  ) {
  | Some(field) => [field]
  | None => [`  ${fieldName}: CommandResult!`]
  }

  let pendingQueue: ref<array<pendingCall>> = ref([])
  pendingQueueRegistry->Dict.set(fieldName, pendingQueue)

  let queuingReceive: receive = (inputJson, ~caller=?) =>
    Promise.make((resolve, _reject) => {
      pendingQueue.contents->Array.push({inputJson, caller, resolve})
    })
  receiveRegistry->Dict.set(fieldName, queuingReceive)

  let resolver: ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn = async (
    _root,
    args,
    ctx,
  ) => {
    let caller = CommandGeneratorResolvers_GraphQL.extractIdentity(ctx)
    let admitted =
      permission->Option.mapOr(false, rule => Reventless.Authorization.isAllowed(rule, caller))
    if !admitted {
      CommandGeneratorResolvers_GraphQL.rejectForbidden(~field=fieldName)
    } else {
      let receive = receiveRegistry->Dict.getUnsafe(fieldName)
      let result = await receive(args->Obj.magic, ~caller)
      result
      ->InboundTranslationSlice_Callback.receiveResultToOutcome
      ->CommandTopic.commandOutcomeToJson
    }
  }

  let resolvers = Dict.make()
  resolvers->Dict.set(fieldName, resolver)
  server.registerMutations(~sdlFields, ~resolvers)
}

// Phase 2: bind the real receive, replacing the forwarder and draining its queue.
let bindReceive = (~fieldName: string, ~receive: receive) => {
  receiveRegistry->Dict.set(fieldName, receive)
  switch pendingQueueRegistry->Dict.get(fieldName) {
  | Some(pendingQueue) =>
    let pending = pendingQueue.contents
    pendingQueue.contents = []
    pending->Array.forEach(({inputJson, caller, resolve}) => {
      let _ = receive(inputJson, ~caller?)->Promise.thenResolve(result => resolve(result))
    })
  | None => ()
  }
}
