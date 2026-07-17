// LocalGraphQL_Adapter — implements ReventlessInfra.Api_Adapter.Provider for
// the in-memory graphql-yoga server.
//
// makeApiResource: no-op (server lifecycle is managed by DomainGraphQL_Server.start)
// generateFragment: delegates to ReventlessCore.GraphQL_FragmentGenerator

type api = unit
type role = unit

let makeApiResource = (
  ~name as _: string,
  ~opts as _: Pulumi.ComponentResource.options,
): (Pulumi.Output.t<api>, Pulumi.Output.t<role>) => (Pulumi.Output.make(()), Pulumi.Output.make(()))

let generateFragment = (
  ~mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  ~queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
): Reventless.Plugin.apiSchemaFragment =>
  ReventlessCore.GraphQL_FragmentGenerator.generate(~mutationEntries, ~queryEntries)
