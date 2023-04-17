let containsByPredicate: (array<'a>, 'a => bool) => bool = (arr, predicate) =>
  arr->Belt.Array.getBy(predicate)->Belt.Option.isSome
