/**
Provider abstraction for the `Api` (GraphQL) component.

Concrete providers (AppSync, graphql-yoga in-memory) implement this module type
so that `Api_Builder.Make` can be parameterised without depending on AWS SDK
or graphql-yoga directly.
*/
module type Provider = {
  type api
  type role

  /**
  Provision the underlying API resource (e.g. AppSync GraphQL API + IAM role).
  Returns the opaque resource handles wrapped in `Output.t`.
  */
  let makeApiResource: (
    ~name: string,
    ~opts: Pulumi.ComponentResource.options,
  ) => (Pulumi.Output.t<api>, Pulumi.Output.t<role>)

  /**
  Generate a schema fragment for one plugin from its mutation and query entries.
  This is called at deploy-time by `Plugin_Builder`.
  */
  let generateFragment: (
    ~mutationEntries: array<Api.mutationSchemaEntry>,
    ~queryEntries: array<Api.querySchemaEntry>,
  ) => Reventless.Plugin.apiSchemaFragment
}
