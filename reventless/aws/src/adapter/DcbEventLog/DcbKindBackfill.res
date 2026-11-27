/***
Tags the stored events of a kind that a slice has begun to read whole. A writer tags only what it
writes, so the events stored before the deploy carry no kind tag and the whole read misses them.
This tags each once, moves the kind's fence so a reader in flight conflicts, and then counts the
fence as `count-fences` does.
*/

open AwsSdk.DynamoDb.DocumentClient

module Runtime = DcbEventLogStorage_DynamoDb_Runtime

let kindAttr = Runtime.tagToAttributeName(Reventless.DcbTag.kindTagKey)

/** The keys of the stored events of `eventType` that carry no kind tag yet. */
let untagged = async (table: Util_DynamoDb_Runtime.resolvedTable, ~eventType: string): array<
  dict<JSON.t>,
> => {
  let items = await Util_DynamoDb_Runtime.scanStream({
    tableName: table.name,
    consistentRead: true,
    filterExpression: "#evt = :type AND attribute_not_exists(#kind)",
    expressionAttributeNames: Dict.fromArray([("#evt", "event"), ("#kind", kindAttr)]),
    expressionAttributeValues: Dict.fromArray([(":type", eventType->JSON.Encode.string)]),
  })
  ->Stream.runCollect
  ->Effect.catchAll(err => Effect.fail(DynamoDb_Error.message(err)))
  ->Effect.runPromise
  items->Array.filterMap(item =>
    item
    ->JSON.Decode.object
    ->Option.flatMap(o =>
      switch (o->Dict.get("id"), o->Dict.get("position")) {
      | (Some(id), Some(position)) => Some(Dict.fromArray([("id", id), ("position", position)]))
      | _ => None
      }
    )
  )
}

/** Adds the kind tag to one stored event, unless it has it already. */
let tagUpdate = (
  table: Util_DynamoDb_Runtime.resolvedTable,
  key: dict<JSON.t>,
  ~eventType: string,
): UpdateCommand.input => {
  let tag = Reventless.DcbTag.kindTag(eventType)
  let tagJson =
    Dict.fromArray([
      ("key", tag.key->JSON.Encode.string),
      ("value", tag.value->JSON.Encode.string),
    ])->JSON.Encode.object
  {
    tableName: table.name,
    key,
    updateExpression: "SET #kind = :type, #tags = list_append(if_not_exists(#tags, :none), :tag)",
    conditionExpression: "attribute_exists(id) AND attribute_not_exists(#kind)",
    expressionAttributeNames: Dict.fromArray([("#kind", kindAttr), ("#tags", "tags")]),
    expressionAttributeValues: Dict.fromArray([
      (":type", eventType->JSON.Encode.string),
      (":none", []->JSON.Encode.array),
      (":tag", [tagJson]->JSON.Encode.array),
    ]),
  }
}

/** Moves the kind's fence, creating it where no writer has yet: a reader that read the kind
    before its events were tagged conflicts, and `count-fences` finds a fence to count. */
let fenceTouch = (
  table: Util_DynamoDb_Runtime.resolvedTable,
  ~eventType: string,
): UpdateCommand.input => {
  tableName: table.name,
  key: Runtime.fenceKey(Reventless.DcbTag.kindTag(eventType)),
  updateExpression: "SET #pos = :pos",
  expressionAttributeNames: Dict.fromArray([("#pos", Runtime.fenceTypeAttr(eventType))]),
  expressionAttributeValues: Dict.fromArray([
    (":pos", Runtime.generatePosition()->JSON.Encode.string),
  ]),
}

let send = (input: UpdateCommand.input) =>
  Effect.tryPromise(~catch=DynamoDb_Error.classify, () =>
    input->UpdateCommand.make->UpdateCommand.send
  )
  ->Effect.retry(DynamoDb_Error.retrySchedule)
  ->Effect.map(_ => true)
  ->Effect.catchAll(err =>
    switch err {
    // Tagged meanwhile by another run.
    | DynamoDb_Error.StaleState(_) => Effect.succeed(false)
    | Transient(msg) | Permanent(msg) => Effect.fail(msg)
    }
  )
  ->Effect.runPromise

/** Tags the stored events of each of `eventTypes` by their kind, and moves each kind's fence.
    Reports how many events of each type it tagged, or with `dryRun` would tag. */
let tagKinds = async (
  table: Util_DynamoDb_Runtime.resolvedTable,
  ~eventTypes: array<string>,
  ~dryRun: bool,
): array<(string, int)> => {
  let tagged = []
  for i in 0 to eventTypes->Array.length - 1 {
    let eventType = eventTypes->Array.getUnsafe(i)
    let keys = await untagged(table, ~eventType)
    if dryRun {
      tagged->Array.push((eventType, keys->Array.length))
    } else {
      let n = ref(0)
      for j in 0 to keys->Array.length - 1 {
        if await send(tagUpdate(table, keys->Array.getUnsafe(j), ~eventType)) {
          n := n.contents + 1
        }
      }
      let _ = await send(fenceTouch(table, ~eventType))
      tagged->Array.push((eventType, n.contents))
    }
  }
  tagged
}
