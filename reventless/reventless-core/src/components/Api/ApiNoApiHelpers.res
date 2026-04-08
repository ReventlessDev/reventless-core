open ReventlessInfra.Api

let isNoApi = (commandSchema: S.t<unknown>): bool =>
  commandSchema->S.Metadata.get(~id=noApiId)->Option.getOr(false)

let getExcludedVariants = (commandSchema: S.t<unknown>): option<Set.t<string>> =>
  commandSchema->S.Metadata.get(~id=noApiVariantsId)

let filterNoApiVariants = (fieldNames: array<string>, commandSchema: S.t<unknown>): array<string> =>
  switch commandSchema->S.Metadata.get(~id=noApiVariantsId) {
  | None => fieldNames
  | Some(excluded) => fieldNames->Array.filter(name => !(excluded->Set.has(name)))
  }
