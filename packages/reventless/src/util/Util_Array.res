let containsByPredicate: (array<'a>, 'a => bool) => bool = (arr, predicate) =>
  arr->Array.find(predicate)->Belt.Option.isSome
