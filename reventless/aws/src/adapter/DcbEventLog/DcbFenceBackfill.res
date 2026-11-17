/***
Completes the counts of cross-partition fences, so readers may trust them. A
writer counts only what it writes, so a fence that existed before counting began,
or that a writer still on the old code moved since, counts too few. This counts
every event of each type that carries the tag, through the index, and sets the
fence's counts to that, on condition that no writer moved them meanwhile.
*/

open AwsSdk.DynamoDb.DocumentClient

module Runtime = DcbEventLogStorage_DynamoDb_Runtime

/** The tag a fence item's id names: `fence#<key>:<value>`. */
let tagOfFenceId = (id: string): option<Reventless.DcbTag.tag> =>
  switch id->String.startsWith("fence#") {
  | false => None
  | true =>
    let rest = id->String.slice(~start=6)
    switch rest->String.indexOf(":") {
    | -1 => None
    | i =>
      Some({key: rest->String.slice(~start=0, ~end=i), value: rest->String.slice(~start=i + 1)})
    }
  }

/** The fences of `keys`, all of them or only those not yet counted. A fence item
    is the one item that holds no event. */
let listFences = async (
  table: Util_DynamoDb_Runtime.resolvedTable,
  ~keys: array<string>,
  ~recount: bool,
): array<Reventless.DcbTag.tag> => {
  let filterExpression = recount
    ? "attribute_not_exists(#evt)"
    : "attribute_not_exists(#evt) AND attribute_not_exists(counted)"
  let items = await Util_DynamoDb_Runtime.scanStream({
    tableName: table.name,
    filterExpression,
    expressionAttributeNames: Dict.fromArray([("#evt", "event")]),
  })
  ->Stream.runCollect
  ->Effect.catchAll(err => Effect.fail(DynamoDb_Error.message(err)))
  ->Effect.runPromise
  items->Array.filterMap(item =>
    item
    ->JSON.Decode.object
    ->Option.flatMap(o => o->Dict.get("id"))
    ->Option.flatMap(JSON.Decode.string)
    ->Option.flatMap(tagOfFenceId)
    ->Option.flatMap(tag => keys->Array.includes(tag.key) ? Some(tag) : None)
  )
}

/** Every event carrying `tag`, counted by type, through the tag's index. */
let countEvents = async (table: Util_DynamoDb_Runtime.resolvedTable, tag) => {
  let counts = Dict.make()
  let items = await Runtime.queryBySingleTagCrossPartitionStream(table, tag)
  ->Stream.runCollect
  ->Effect.runPromise
  items->Array.forEach(item =>
    switch item
    ->JSON.Decode.object
    ->Option.flatMap(o => o->Dict.get("event"))
    ->Option.flatMap(JSON.Decode.string) {
    | Some(eventType) =>
      counts->Dict.set(eventType, counts->Dict.get(eventType)->Option.getOr(0) + 1)
    | None => ()
    }
  )
  counts
}

/** Sets a fence's counts to `total` and marks it counted, if they are still `before`. */
let countUpdate = (
  table: Util_DynamoDb_Runtime.resolvedTable,
  tag: Reventless.DcbTag.tag,
  ~before: dict<int>,
  ~total: dict<int>,
  ~cut: string,
): UpdateCommand.input => {
  let names = Dict.fromArray([("#cf", Runtime.countedFromAttr)])
  let values = Dict.fromArray([
    (":true", JSON.Encode.bool(true)),
    (":cut", cut->JSON.Encode.string),
  ])
  let types = Array.concat(before->Dict.keysToArray, total->Dict.keysToArray)->Runtime.dedupStrings
  let sets = []
  let conditions = ["attribute_exists(id)"]
  types->Array.forEachWithIndex((eventType, i) => {
    let ph = `#n${i->Int.toString}`
    names->Dict.set(ph, Runtime.fenceCountAttr(eventType))
    let t = `:t${i->Int.toString}`
    values->Dict.set(t, total->Dict.get(eventType)->Option.getOr(0)->Int.toFloat->JSON.Encode.float)
    sets->Array.push(`${ph} = ${t}`)
    switch before->Dict.get(eventType) {
    | Some(n) =>
      let b = `:b${i->Int.toString}`
      values->Dict.set(b, n->Int.toFloat->JSON.Encode.float)
      conditions->Array.push(`${ph} = ${b}`)
    | None => conditions->Array.push(`attribute_not_exists(${ph})`)
    }
  })
  {
    tableName: table.name,
    key: Runtime.fenceKey(tag),
    updateExpression: `SET ${sets
      ->Array.concat(["counted = :true", "#cf = if_not_exists(#cf, :cut)"])
      ->Array.join(", ")}`,
    conditionExpression: conditions->Array.join(" AND "),
    expressionAttributeNames: names,
    expressionAttributeValues: values,
  }
}

type outcome =
  /** The counts were set, or with `dryRun` would be. */
  | Counted({before: dict<int>, total: dict<int>})
  /** A writer moved the fence while it was counted; count it again. */
  | Moved
  /** The index shows fewer events than the fence already counted: it is behind. */
  | IndexBehind({before: dict<int>, total: dict<int>})

/** Counts one fence read before the index settled. */
let countFence = async (
  table: Util_DynamoDb_Runtime.resolvedTable,
  fence: Reventless.DcbFenceCount.fence,
  ~dryRun: bool,
): result<outcome, string> => {
  let before = fence.counts
  let total = await countEvents(table, fence.tag)
  let behind =
    before
    ->Dict.toArray
    ->Array.some(((eventType, n)) => total->Dict.get(eventType)->Option.getOr(0) < n)
  if behind {
    Ok(IndexBehind({before, total}))
  } else if dryRun {
    Ok(Counted({before, total}))
  } else {
    let input = countUpdate(table, fence.tag, ~before, ~total, ~cut=Runtime.generatePosition())
    await Effect.tryPromise(~catch=DynamoDb_Error.classify, () =>
      input->UpdateCommand.make->UpdateCommand.send
    )
    ->Effect.map(_ => Ok(Counted({before, total})))
    ->Effect.catchAll(err =>
      switch err {
      | DynamoDb_Error.StaleState(_) => Effect.succeed(Ok(Moved))
      | Transient(msg) | Permanent(msg) => Effect.succeed(Error(msg))
      }
    )
    ->Effect.runPromise
  }
}

/** Counts `tags`: reads their fences, waits `settleMs` for the index to show
    every write made before, counts each, and counts again those a writer moved
    meanwhile, `rounds` times at most. Reports each fence's last outcome. */
let rec countFences = async (
  table: Util_DynamoDb_Runtime.resolvedTable,
  tags: array<Reventless.DcbTag.tag>,
  ~settleMs: int,
  ~dryRun: bool,
  ~rounds: int=3,
): array<(Reventless.DcbTag.tag, result<outcome, string>)> =>
  switch tags {
  | [] => []
  | tags =>
    let fences = await Runtime.readFences(table)(tags)
    await Effect.sleep(Duration.millis(settleMs))->Effect.runPromise
    let outcomes = []
    for i in 0 to fences->Array.length - 1 {
      let fence = fences->Array.getUnsafe(i)
      outcomes->Array.push((fence.tag, await countFence(table, fence, ~dryRun)))
    }
    let moved = outcomes->Array.filterMap(((tag, o)) => o == Ok(Moved) ? Some(tag) : None)
    let settled = outcomes->Array.filter(((_, o)) => o != Ok(Moved))
    rounds > 1 && moved != []
      ? settled->Array.concat(
          await countFences(table, moved, ~settleMs, ~dryRun, ~rounds=rounds - 1),
        )
      : outcomes
  }
