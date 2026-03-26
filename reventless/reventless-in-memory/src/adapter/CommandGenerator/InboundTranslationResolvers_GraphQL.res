// GraphQL mutation resolvers for in-memory InboundTranslationSlices.
// Registers one GraphQL mutation field per InboundTranslationSlice.
// Each resolver calls `receive(argsJson)` directly — the InboundTranslationSlice
// handles parsing, validation, translation, and command publishing internally.

@@warning("-44")
open ReventlessCore

// Mutable registry: fieldName → receive function.
// Populated when Output.apply resolves (after GraphQL server starts).
let receiveRegistry: dict<JSON.t => promise<result<string, string>>> = Dict.make()

// Phase 1: Register SDL + resolver stub synchronously (before server starts).
let register = (~fieldName: string, ~externalInputSchema: S.t<unknown>) => {
  let sdlFields = switch GraphQL_FragmentGenerator.deriveMutationFieldFromObject(
    ~fieldName,
    externalInputSchema,
  ) {
  | Some(field) => [field]
  | None => [`  ${fieldName}: String!`]
  }

  let resolver: GraphQL_Server.resolverFn = async (_root, args, _ctx) => {
    let inputJson: JSON.t = args->Obj.magic
    switch receiveRegistry->Dict.get(fieldName) {
    | Some(receive) =>
      let result = await receive(inputJson)
      switch result {
      | Ok(targetId) => targetId->JSON.Encode.string
      | Error(msg) => msg->JSON.Encode.string
      }
    | None => `error: no receive handler registered for ${fieldName}`->JSON.Encode.string
    }
  }

  let resolvers = Dict.make()
  resolvers->Dict.set(fieldName, resolver)
  GraphQL_Server.registerMutations(~sdlFields, ~resolvers)
}

// Phase 2: Bind the receive function once Output.apply resolves.
let bindReceive = (~fieldName: string, ~receive: JSON.t => promise<result<string, string>>) => {
  receiveRegistry->Dict.set(fieldName, receive)
}
