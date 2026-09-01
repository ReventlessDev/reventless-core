open ReventlessInfra.Api

let isNoApi = (commandSchema: S.t<unknown>): bool =>
  commandSchema->S.Metadata.get(~id=noApiId)->Option.getOr(false)

// Variants excluded by a mark on the member itself. This is the half that
// survives a spread: splicing copies members, not the metadata of the union they
// came from, so a command a trait marked internal is only still recognisable here.
let excludedByMembers = (commandSchema: S.t<unknown>): array<string> =>
  switch commandSchema {
  | AnyOf({anyOf}) =>
    anyOf->Array.filterMap(member =>
      member->S.Metadata.get(~id=noApiVariantId)->Option.getOr(false)
        ? variantNameOf(member)
        : None
    )
  | _ => []
  }

/**
Every variant excluded from the API, from both records of the fact.

The union's own set covers variants the schema's author declared; the members'
marks cover variants spliced in from another type, whose author's declaration is
in a file this one never mentions. A reader that consulted only the first
published someone else's internal commands.

`None` still means "nothing is excluded", so a caller's existing branch is
unchanged.
*/
let getExcludedVariants = (commandSchema: S.t<unknown>): option<Set.t<string>> => {
  let fromMembers = excludedByMembers(commandSchema)
  switch (commandSchema->S.Metadata.get(~id=noApiVariantsId), fromMembers) {
  | (None, []) => None
  | (None, members) => Some(Set.fromArray(members))
  | (Some(declared), []) => Some(declared)
  | (Some(declared), members) =>
    let all = declared->Set.toArray->Array.concat(members)
    Some(Set.fromArray(all))
  }
}

let filterNoApiVariants = (fieldNames: array<string>, commandSchema: S.t<unknown>): array<string> =>
  switch getExcludedVariants(commandSchema) {
  | None => fieldNames
  | Some(excluded) => fieldNames->Array.filter(name => !(excluded->Set.has(name)))
  }
