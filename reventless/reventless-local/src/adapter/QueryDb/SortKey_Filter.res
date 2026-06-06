// Pure sort key filtering for sub-ID queries.
// Applies DynamoDB-style sort key conditions to an already-sorted item list.
// Used by QueryDbResolvers_GraphQL for {name}ById queries.

type result = {
  items: array<JSON.t>,
  nextToken: option<string>,
}

/** Extract the sort key string from a JSON item using the given field name. */
let getSk = (item, skField) =>
  item->JSON.Decode.object->Option.flatMap(d => d->Dict.get(skField))->Option.flatMap(JSON.Decode.string)->Option.getOr("")

/** Apply sort key conditions, ordering, and pagination to a list of JSON items.
    - `items` must already be sorted ascending by sort key.
    - Returns filtered+paginated items and an optional `nextToken` for the next page. */
let apply = (
  ~items: array<JSON.t>,
  ~skField: string,
  ~prefix: option<string>=?,
  ~from: option<string>=?,
  ~to_: option<string>=?,
  ~eq: option<string>=?,
  ~reverse: bool=false,
  ~limit: option<int>=?,
  ~offset: int=0,
) => {
  let filtered = items->Array.filter(item => {
    let sk = getSk(item, skField)
    let okPrefix = prefix->Option.map(p => sk->String.startsWith(p))->Option.getOr(true)
    let okFrom   = from->Option.map(f => sk >= f)->Option.getOr(true)
    let okTo     = to_->Option.map(t => sk <= t)->Option.getOr(true)
    let okEq     = eq->Option.map(e => sk == e)->Option.getOr(true)
    okPrefix && okFrom && okTo && okEq
  })
  let ordered = if reverse { filtered->Array.toReversed } else { filtered }
  let sliced = ordered->Array.slice(~start=offset, ~end=ordered->Array.length)
  let (page, hasMore) = switch limit {
  | Some(n) => (sliced->Array.slice(~start=0, ~end=n), sliced->Array.length > n)
  | None => (sliced, false)
  }
  let nextToken = if hasMore {
    Some(Int.toString(offset + page->Array.length))
  } else {
    None
  }
  { items: page, nextToken }
}
