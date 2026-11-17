/***
Completes the counts of cross-partition fences, so readers may trust them. A
writer counts only what it writes, so a fence that existed before counting began,
or that a writer still on the old code moved since, counts too few. This counts
every event of each type that carries the tag, through the index, and sets the
fence's counts to that, on condition that no writer moved them meanwhile.
*/

open AwsSdk.DynamoDb.DocumentClient

module Runtime = DcbEventLogStorage_DynamoDb_Runtime

/** A fence item: a key value's own, or a pair's, which counts one event type. */
type fenceRef = {
  tag: Reventless.DcbTag.tag,
  eventType?: string,
}

let fenceRefText = (f: fenceRef) =>
  `${f.tag.key}=${f.tag.value}${f.eventType->Option.mapOr("", t => ` (${t})`)}`

let keyOfRef = (f: fenceRef) =>
  switch f.eventType {
  | Some(eventType) => Runtime.pairFenceKey(f.tag, eventType)
  | None => Runtime.fenceKey(f.tag)
  }

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

/** The fences of `keys`, and the pair fences of `pairs` (key, event type), all of
    them or only those not yet counted. A fence item is the one item that holds no
    event; a pair's sorts as `FENCE#<eventType>`. The scan is strongly consistent,
    so every fence written before it began is listed. */
let listFences = async (
  table: Util_DynamoDb_Runtime.resolvedTable,
  ~keys: array<string>,
  ~pairs: array<(string, string)>=[],
  ~recount: bool,
): array<fenceRef> => {
  let filterExpression = recount
    ? "attribute_not_exists(#evt)"
    : "attribute_not_exists(#evt) AND attribute_not_exists(counted)"
  let items = await Util_DynamoDb_Runtime.scanStream({
    tableName: table.name,
    consistentRead: true,
    filterExpression,
    expressionAttributeNames: Dict.fromArray([("#evt", "event")]),
  })
  ->Stream.runCollect
  ->Effect.catchAll(err => Effect.fail(DynamoDb_Error.message(err)))
  ->Effect.runPromise
  let pairPrefix = `${Runtime.fenceSortKey}#`
  items->Array.filterMap(item => {
    let attr = name =>
      item
      ->JSON.Decode.object
      ->Option.flatMap(o => o->Dict.get(name))
      ->Option.flatMap(JSON.Decode.string)
    switch (attr("id")->Option.flatMap(tagOfFenceId), attr("position")) {
    | (Some(tag), Some(sortKey)) if sortKey == Runtime.fenceSortKey =>
      keys->Array.includes(tag.key) ? Some({tag: tag}) : None
    | (Some(tag), Some(sortKey)) if sortKey->String.startsWith(pairPrefix) =>
      let eventType = sortKey->String.slice(~start=pairPrefix->String.length)
      pairs->Array.some(((k, t)) => k == tag.key && t == eventType) ? Some({tag, eventType}) : None
    | _ => None
    }
  })
}

/** Every event carrying `tag`, counted by type, through the tag's index; only
    `eventType`'s, when given. */
let countEvents = async (table: Util_DynamoDb_Runtime.resolvedTable, tag, ~eventType=?) => {
  let counts = Dict.make()
  let items = await Runtime.queryBySingleTagCrossPartitionStream(table, tag)
  ->Stream.runCollect
  ->Effect.runPromise
  items->Array.forEach(item =>
    switch item
    ->JSON.Decode.object
    ->Option.flatMap(o => o->Dict.get("event"))
    ->Option.flatMap(JSON.Decode.string) {
    | Some(t) if eventType->Option.mapOr(true, only => only == t) =>
      counts->Dict.set(t, counts->Dict.get(t)->Option.getOr(0) + 1)
    | _ => ()
    }
  )
  counts
}

/** Sets a fence's counts to `total` and marks it counted, if they are still `before`. */
let countUpdate = (
  table: Util_DynamoDb_Runtime.resolvedTable,
  fence: fenceRef,
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
    key: keyOfRef(fence),
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

/** Counts one fence, given the counts it held before the index settled. */
let countFence = async (
  table: Util_DynamoDb_Runtime.resolvedTable,
  fence: fenceRef,
  ~before: dict<int>,
  ~dryRun: bool,
): result<outcome, string> => {
  let total = await countEvents(table, fence.tag, ~eventType=?fence.eventType)
  let behind =
    before
    ->Dict.toArray
    ->Array.some(((eventType, n)) => total->Dict.get(eventType)->Option.getOr(0) < n)
  if behind {
    Ok(IndexBehind({before, total}))
  } else if dryRun {
    Ok(Counted({before, total}))
  } else {
    let input = countUpdate(table, fence, ~before, ~total, ~cut=Runtime.generatePosition())
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
  fences: array<fenceRef>,
  ~settleMs: int,
  ~dryRun: bool,
  ~rounds: int=3,
): array<(fenceRef, result<outcome, string>)> =>
  switch fences {
  | [] => []
  | fences =>
    let befores = await fences
    ->Array.map(async f =>
      Runtime.fenceOfItem(f.tag, await Runtime.getFenceItem(table, keyOfRef(f))).counts
    )
    ->Promise.all
    await Effect.sleep(Duration.millis(settleMs))->Effect.runPromise
    let outcomes = []
    for i in 0 to fences->Array.length - 1 {
      let fence = fences->Array.getUnsafe(i)
      let before = befores->Array.getUnsafe(i)
      outcomes->Array.push((fence, await countFence(table, fence, ~before, ~dryRun)))
    }
    let moved = outcomes->Array.filterMap(((f, o)) => o == Ok(Moved) ? Some(f) : None)
    let settled = outcomes->Array.filter(((_, o)) => o != Ok(Moved))
    rounds > 1 && moved != []
      ? settled->Array.concat(
          await countFences(table, moved, ~settleMs, ~dryRun, ~rounds=rounds - 1),
        )
      : outcomes
  }

/** Records, for each key and pair, that its fences were counted as of `cut`. */
let recordCuts = async (
  table: Util_DynamoDb_Runtime.resolvedTable,
  ~keys: array<string>,
  ~pairs: array<(string, string)>,
  ~cut: string,
) => {
  let put = key => {
    let item = key->Dict.copy
    item->Dict.set(Runtime.cutAttr, cut->JSON.Encode.string)
    Effect.tryPromise(~catch=DynamoDb_Error.classify, () =>
      PutCommand.send(PutCommand.make({tableName: table.name, item: item->JSON.Encode.object}))
    )
    ->Effect.retry(DynamoDb_Error.retrySchedule)
    ->Effect.catchAll(err => Effect.fail(DynamoDb_Error.message(err)))
    ->Effect.runPromise
  }
  let _ = await keys
  ->Array.map(k => Runtime.cutKey(k))
  ->Array.concat(pairs->Array.map(((k, eventType)) => Runtime.cutKey(k, ~eventType)))
  ->Array.map(put)
  ->Promise.all
}

/** Counts the fences of `keys` and `pairs`, and when every one of them is counted,
    records the position taken before the scan, so a fence that begins counting
    after it is trusted without a run of its own. Reports each fence's last outcome,
    and whether the position was recorded. */
let countAll = async (
  table: Util_DynamoDb_Runtime.resolvedTable,
  ~keys: array<string>,
  ~pairs: array<(string, string)>,
  ~recount: bool,
  ~settleMs: int,
  ~dryRun: bool,
): (array<(fenceRef, result<outcome, string>)>, bool) => {
  let cut = Runtime.generatePosition()
  let fences = await listFences(table, ~keys, ~pairs, ~recount)
  let outcomes = await countFences(table, fences, ~settleMs, ~dryRun)
  let complete = outcomes->Array.every(((_, o)) =>
    switch o {
    | Ok(Counted(_)) => true
    | _ => false
    }
  )
  if complete && !dryRun {
    await recordCuts(table, ~keys, ~pairs, ~cut)
    (outcomes, true)
  } else {
    (outcomes, false)
  }
}
