let baseFragment = {
  // Start with the auto-generated Plugin aggregate fragment
  let parts = GraphQL_Stitcher.decode(PluginBaseFragment.fragment)

  // Add the clone mutation (core-level operation, not part of any aggregate)
  let cloneMutation = `  clone(restoreDateTime: String): String!`
  let allMutations = Array.concat(parts.mutations, [cloneMutation])

  let encoded =
    JSON.Encode.object(
      Dict.fromArray([
        ("types", JSON.Encode.array(parts.types->Array.map(JSON.Encode.string))),
        ("mutations", JSON.Encode.array(allMutations->Array.map(JSON.Encode.string))),
        ("queries", JSON.Encode.array(parts.queries->Array.map(JSON.Encode.string))),
      ]),
    )->JSON.stringify

  {Reventless.Plugin.encoded, protocol: "graphql"}
}
