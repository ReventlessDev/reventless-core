open Util_DynamoDb_Runtime
open AwsSdk.DynamoDb.DocumentClient

// --- Position Generation ---

let generatePosition = () => {
  let timestamp = Date.make()->Date.getTime->Float.toString
  let uuid = Uuid.v4()
  `${timestamp}-${uuid}`
}

let generatePositionForBatch = (basePosition, index) => {
  if index == 0 {
    basePosition
  } else {
    `${basePosition}-${index->Int.toString->String.padStart(3, "0")}`
  }
}

// --- Tag Utilities ---

let tagToAttributeName = (tagKey: string) => `tag_${tagKey}`

let compositeTagKey = (tags: array<Reventless.DcbTag.tag>) =>
  tags
  ->Array.toSorted((a, b) => String.compare(a.key, b.key))
  ->Array.map(t => `${t.key}:${t.value}`)
  ->Array.join("#")

// --- Partition Key Derivation ---

let derivePartitionKey = (
  ~partitionTag: option<Reventless.DcbTag.derivedPartitionTag>=?,
  tags: array<Reventless.DcbTag.tag>,
): string => {
  if tags->Array.length == 0 {
    "dcb"
  } else {
    switch partitionTag {
    | None =>
      let tag = tags->Array.getUnsafe(0)
      `${tag.key}:${tag.value}`
    | Some(Simple(pt)) =>
      let tag = switch tags->Array.find(t => t.key == pt.key) {
      | Some(t) => t
      | None => tags->Array.getUnsafe(0)
      }
      `${tag.key}:${tag.value}`
    | Some(Composite(spec)) =>
      Reventless.DcbTag.getCompositePartitionKeyValue(tags, spec)
    }
  }
}

// --- Item Conversion ---

let toItem = (
  position: string,
  event: ReventlessCore.DcbEventLog_Adapter.rawStoredEvent,
  ~partitionTag=?,
  ~recordedAt: string,
): JSON.t => {
  // Create base item
  let item = Dict.make()
  item->Dict.set("id", derivePartitionKey(~partitionTag?, event.tags)->JSON.Encode.string)
  item->Dict.set("position", position->JSON.Encode.string)
  item->Dict.set("event", event.eventType->JSON.Encode.string)
  item->Dict.set("data", event.data)
  item->Dict.set("recordedAt", recordedAt->JSON.Encode.string)

  // Add tags array
  let tagsJson = event.tags->Array.map(tag =>
    [
      ("key", tag.key->JSON.Encode.string),
      ("value", tag.value->JSON.Encode.string),
    ]
    ->Dict.fromArray
    ->JSON.Encode.object
  )
  item->Dict.set("tags", tagsJson->JSON.Encode.array)

  // Flatten meta.* to top-level item attributes so individual meta keys stay
  // GSI-projectable (matches the EventLog adapter behaviour). The DCB read
  // path reassembles meta via `Reventless.Message.composeMeta`.
  event.meta
  ->ReventlessCore.Message.decomposeMeta
  ->Array.forEach(((k, v)) => item->Dict.set(k, v))

  // Add individual tag attributes for GSI queries
  event.tags->Array.forEach(tag => {
    let attrName = tagToAttributeName(tag.key)
    item->Dict.set(attrName, tag.value->JSON.Encode.string)
  })

  // Add composite tag attribute if multiple tags
  if event.tags->Array.length > 1 {
    let composite = compositeTagKey(event.tags)
    item->Dict.set("tag_composite", composite->JSON.Encode.string)
  }

  item->JSON.Encode.object
}

let fromItem = (item: JSON.t): ReventlessCore.DcbEventLog_Adapter.rawSequencedEvent => {
  switch item->JSON.Decode.object {
  | None => JsError.throwWithMessage("Invalid DcbEventLog item: not an object")
  | Some(obj) =>
    let position = obj
    ->Dict.get("position")
    ->Option.flatMap(JSON.Decode.string)
    ->Option.getOrThrow

    let eventType = obj
    ->Dict.get("event")
    ->Option.flatMap(JSON.Decode.string)
    ->Option.getOrThrow

    let data = obj->Dict.get("data")->Option.getOrThrow

    let tags = obj
    ->Dict.get("tags")
    ->Option.flatMap(JSON.Decode.array)
    ->Option.mapOr([], tagArray =>
      tagArray->Array.filterMap(tagJson =>
        switch tagJson->JSON.Decode.object {
        | None => None
        | Some(tagObj) => {
            let key = tagObj->Dict.get("key")->Option.flatMap(JSON.Decode.string)
            let value = tagObj->Dict.get("value")->Option.flatMap(JSON.Decode.string)
            switch (key, value) {
            | (Some(k), Some(v)) => Some({Reventless.DcbTag.key: k, value: v})
            | _ => None
            }
          }
        }
      )
    )

    let recordedAt =
      obj
      ->Dict.get("recordedAt")
      ->Option.flatMap(JSON.Decode.string)
      ->Option.getOr("")

    let meta =
      obj
      ->ReventlessCore.Message.composeMeta
      ->S.parseJsonOrThrow(Reventless.Message.metaSchema)

    {
      position,
      eventType,
      data,
      tags,
      meta,
      recordedAt,
    }
  }
}

// --- Query Operations ---

let queryBySingleTag = async (
  table: resolvedTable,
  tagKey: string,
  tagValue: string,
  ~after: option<string>=?,
) => {
  let indexName = tagToAttributeName(tagKey)

  let expressionAttributeValues = Dict.fromArray([
    (":val", tagValue->JSON.Encode.string),
  ])

  let (keyConditionExpression, expressionAttributeNames) = switch after {
  | None => (`${indexName} = :val`, None)
  | Some(afterPos) => {
      expressionAttributeValues->Dict.set(":after", afterPos->JSON.Encode.string)
      (`${indexName} = :val AND #pos > :after`, Some(Dict.fromArray([("#pos", "position")])))
    }
  }

  let queryParams: QueryCommand.input = {
    tableName: table.name,
    indexName: indexName,
    keyConditionExpression: keyConditionExpression,
    expressionAttributeValues: expressionAttributeValues,
    ?expressionAttributeNames,
  }

  await queryStream(queryParams)->Stream.runCollect->Effect.runPromise
}

let queryByCompositeTags = async (
  table: resolvedTable,
  tags: array<Reventless.DcbTag.tag>,
  ~after: option<string>=?,
) => {
  let composite = compositeTagKey(tags)
  let indexName = "tag_composite"

  let expressionAttributeValues = Dict.fromArray([
    (":composite", composite->JSON.Encode.string),
  ])

  let (keyConditionExpression, expressionAttributeNames) = switch after {
  | None => ("tag_composite = :composite", None)
  | Some(afterPos) => {
      expressionAttributeValues->Dict.set(":after", afterPos->JSON.Encode.string)
      ("tag_composite = :composite AND #pos > :after", Some(Dict.fromArray([("#pos", "position")])))
    }
  }

  let queryParams: QueryCommand.input = {
    tableName: table.name,
    indexName: indexName,
    keyConditionExpression: keyConditionExpression,
    expressionAttributeValues: expressionAttributeValues,
    ?expressionAttributeNames,
  }

  await queryStream(queryParams)->Stream.runCollect->Effect.runPromise
}

let scanWithFilter = async (
  table: resolvedTable,
  ~eventTypes: option<array<string>>=?,
  ~after: option<string>=?,
) => {
  let expressionAttributeValues = Dict.make()
  let expressionAttributeNames = Dict.make()

  let filterParts = []

  // Add event type filter
  switch eventTypes {
  | None => ()
  | Some(types) => {
      expressionAttributeNames->Dict.set("#evt", "event")
      let typeConditions = types->Array.mapWithIndex((typ, idx) => {
        let placeholder = `:type${idx->Int.toString}`
        expressionAttributeValues->Dict.set(placeholder, typ->JSON.Encode.string)
        `#evt = ${placeholder}`
      })
      filterParts->Array.push(`(${typeConditions->Array.join(" OR ")})`)
    }
  }

  let filterExpression = if filterParts->Array.length > 0 {
    Some(filterParts->Array.join(" AND "))
  } else {
    None
  }

  let hasAttributeValues = expressionAttributeValues->Dict.keysToArray->Array.length > 0
  let hasAttributeNames = expressionAttributeNames->Dict.keysToArray->Array.length > 0

  let scanParams: ScanCommand.input = {
    tableName: table.name,
    ?filterExpression,
    expressionAttributeValues: ?(hasAttributeValues ? Some(expressionAttributeValues) : None),
    expressionAttributeNames: ?(hasAttributeNames ? Some(expressionAttributeNames) : None),
  }

  // position cannot appear in FilterExpression (it is the table's sort key).
  // Collect all items first, then filter by position in application code.
  let rawItems = await scanStream(scanParams)->Stream.runCollect->Effect.runPromise
  switch after {
  | None => rawItems
  | Some(afterPos) =>
    rawItems->Array.filter(item =>
      item
      ->JSON.Decode.object
      ->Option.flatMap(obj => obj->Dict.get("position"))
      ->Option.flatMap(JSON.Decode.string)
      ->Option.mapOr(false, pos => String.compare(pos, afterPos) > 0.)
    )
  }
}

// --- Partition Key Query (direct table query, no GSI) ---

// Builds the QueryCommand.input for a single-partition lookup against the base
// table. Strong consistency is supported here because base-table reads can
// opt in (GSIs cannot — fundamental DynamoDB constraint), so this helper
// accepts an optional ~strongConsistency flag.
let buildQueryByPartitionKeyInput = (
  table: resolvedTable,
  partitionKey: string,
  ~after: option<string>=?,
  ~strongConsistency: bool=false,
): QueryCommand.input => {
  let expressionAttributeValues = Dict.fromArray([
    (":pk", partitionKey->JSON.Encode.string),
  ])
  let (keyConditionExpression, expressionAttributeNames) = switch after {
  | None => ("id = :pk", None)
  | Some(afterPos) => {
      expressionAttributeValues->Dict.set(":after", afterPos->JSON.Encode.string)
      ("id = :pk AND #pos > :after", Some(Dict.fromArray([("#pos", "position")])))
    }
  }
  let consistentRead = strongConsistency ? Some(true) : None
  {
    tableName: table.name,
    ?consistentRead,
    keyConditionExpression,
    expressionAttributeValues,
    ?expressionAttributeNames,
  }
}

let queryByPartitionKey = async (
  table: resolvedTable,
  partitionKey: string,
  ~after: option<string>=?,
) => {
  let queryParams = buildQueryByPartitionKeyInput(table, partitionKey, ~after?)
  await queryStream(queryParams)->Stream.runCollect->Effect.runPromise
}

// --- Query Item Execution ---

let executeQueryItem = async (
  table: resolvedTable,
  queryItem: Reventless.DcbTag.queryItem,
  ~after: option<string>=?,
) => {
  switch queryItem.tags {
  // Single tag: direct partition key lookup
  | Some([tag]) =>
    await queryByPartitionKey(table, `${tag.key}:${tag.value}`, ~after?)

  // Multiple tags: use composite GSI
  | Some(tags) if tags->Array.length > 1 =>
    await queryByCompositeTags(table, tags, ~after?)

  // No tags (or empty): fall back to scan
  | None | Some([]) | Some(_) =>
    switch queryItem.eventTypes {
    | Some(eventTypes) => await scanWithFilter(table, ~eventTypes, ~after?)
    | None => await scanWithFilter(table, ~after?)
    }
  }
}

// --- Deduplication ---

let deduplicateByPosition = (
  events: array<ReventlessCore.DcbEventLog_Adapter.rawSequencedEvent>,
): array<ReventlessCore.DcbEventLog_Adapter.rawSequencedEvent> => {
  let seen = Set.make()
  events->Array.filter(event => {
    if seen->Set.has(event.position) {
      false
    } else {
      seen->Set.add(event.position)
      true
    }
  })
}

// --- K-way Merge (lazy, position-ordered) ---
//
// Used by readStream when all queryItems are tag-based (GSI queries). Each
// GSI sub-stream returns items in ascending `position` order (rangeKey = "position"),
// so an N-way merge-sort produces a globally-sorted output stream without
// materialising any sub-stream upfront.
//
// Each sub-stream is driven by a dedicated fiber pumping into a bounded Queue(1).
// The merge loop advances only the sub-stream with the current minimum position,
// so DynamoDB pages are fetched lazily — Stream.take(n) short-circuits pagination.

type mergeSlot = {
  queue: Queue.t<option<ReventlessCore.DcbEventLog_Adapter.rawSequencedEvent>>,
  head: option<ReventlessCore.DcbEventLog_Adapter.rawSequencedEvent>,
}

// Wraps a sub-stream in a Queue(1) producer fiber and pulls the first element.
let initSlot = (
  stream: Stream.t<ReventlessCore.DcbEventLog_Adapter.rawSequencedEvent, string, unit>,
): Effect.t<mergeSlot, string, unit> =>
  Queue.bounded(1)->Effect.flatMap(queue => {
    let producer =
      stream
      ->Stream.runForEach(event =>
        Queue.offer(queue, Some(event))->Effect.map(_ => ())
      )
      // Always push the None sentinel so the merge loop can detect exhaustion,
      // even if the stream fails (stream error is suppressed to prevent an
      // unhandled-fiber-failure warning).
      ->Effect.ensuring(Queue.offer(queue, None)->Effect.map(_ => ()))
      ->Effect.catchAll(_ => Effect.succeed(()))
    Effect.fork(producer)->Effect.flatMap(_ =>
      Queue.take(queue)->Effect.map(head => {queue, head})
    )
  })

// Returns the index of the slot with the smallest position, or None if all exhausted.
let findMinSlotIdx = (slots: array<mergeSlot>) =>
  slots->Array.reduceWithIndex(None, (minOpt, slot, idx) =>
    switch (minOpt, slot.head) {
    | (_, None) => minOpt
    | (None, Some(_)) => Some(idx)
    | (Some(minIdx), Some(head)) =>
      let minSlot = slots->Array.getUnsafe(minIdx)
      switch minSlot.head {
      | None => Some(idx)
      | Some(minHead) =>
        String.compare(head.position, minHead.position) < 0. ? Some(idx) : minOpt
      }
    }
  )

// Drops adjacent events with the same position (safe because the merged stream
// is already position-ordered — duplicates are always consecutive).
let dedupByPosition = (
  stream: Stream.t<ReventlessCore.DcbEventLog_Adapter.rawSequencedEvent, string, unit>,
) => {
  let lastPos: ref<option<string>> = ref(None)
  stream->Stream.filter(event =>
    switch lastPos.contents {
    | Some(pos) when pos == event.position => false
    | _ =>
      lastPos := Some(event.position)
      true
    }
  )
}

// Merges N position-sorted streams into one position-sorted stream.
// Requires that every input stream emits events in ascending position order.
let mergeSortedEvents = (
  streams: array<Stream.t<ReventlessCore.DcbEventLog_Adapter.rawSequencedEvent, string, unit>>,
): Stream.t<ReventlessCore.DcbEventLog_Adapter.rawSequencedEvent, string, unit> =>
  streams
  ->Array.map(initSlot)
  ->Effect.all({"concurrency": "unbounded"})
  ->Stream.fromEffect
  ->Stream.flatMap(initialSlots =>
    Stream.paginateEffect(initialSlots, slots =>
      switch findMinSlotIdx(slots) {
      | None =>
        // All sub-streams exhausted — terminate with an empty page.
        Effect.succeed(([], None))
      | Some(idx) =>
        let slot = slots->Array.getUnsafe(idx)
        let emitEvent = slot.head->Option.getOrThrow
        Queue.take(slot.queue)->Effect.map(nextHead => {
          let newSlots = slots->Array.mapWithIndex((s, i) =>
            if i == idx {
              {...s, head: nextHead}
            } else {
              s
            }
          )
          let hasActive = newSlots->Array.some(s => s.head->Option.isSome)
          ([emitEvent], hasActive ? Some(newSlots) : None)
        })
      }
    )
  )

// --- Main Operations ---

let read = (table: resolvedTable) =>
  async (
    ~query: Reventless.DcbTag.query,
    ~after=?,
  ) => {
    // Execute queries for each queryItem
    let queryResults = await query
    ->Array.map(queryItem => executeQueryItem(table, queryItem, ~after?))
    ->Promise.all

    // Merge and deduplicate results
    let allItems = queryResults->Array.flat
    let allEvents = allItems->Array.map(fromItem)
    let deduplicatedEvents = deduplicateByPosition(allEvents)

    // Sort by position
    let sortedEvents = deduplicatedEvents->Array.toSorted((a, b) =>
      String.compare(a.position, b.position)
    )

    // Get head position (latest position)
    let headPosition = sortedEvents
    ->Array.toReversed
    ->Array.at(0)
    ->Option.map(event => event.position)

    {
      ReventlessCore.DcbEventLog_Adapter.events: sortedEvents,
      ?headPosition,
    }
  }

// --- DCB consistency fences ---
//
// A fence is a sentinel item in the same table whose `lastPosition` is bumped
// inside every conditional append. Each tag value (`<key>:<value>`) gets its
// own fence at `id = "fence#<key>:<value>", position = "FENCE"`. The id prefix
// is distinct from event partition keys (`<key>:<value>`), so event reads never
// see fence items.
//
// On conditional append: every tag value present in `cond.query` gets a
// `ConditionalUpdate` checking that nothing has bumped the fence past `after`
// since the slice's decision-model read. Every tag value present in the new
// events' tags ALSO gets bumped (without condition) so future readers querying
// those tags will detect this commit.
//
// All Puts and Updates ride a single `TransactWriteItems` call — atomic by
// DynamoDB. Conflicts surface as `TransactionCanceledException` →
// `DynamoDb_Error.StaleState` → `Error("Conflict: …")`.

let fenceSortKey = "FENCE"

let fencePartitionKey = (tag: Reventless.DcbTag.tag) => `fence#${tag.key}:${tag.value}`

let fenceKey = (tag: Reventless.DcbTag.tag): dict<JSON.t> =>
  Dict.fromArray([
    ("id", fencePartitionKey(tag)->JSON.Encode.string),
    ("position", fenceSortKey->JSON.Encode.string),
  ])

// Collect every distinct tag from a query. Each queryItem's tags are AND'd,
// across queryItems they're OR'd — both contribute to the fence set.
let collectQueryTags = (query: Reventless.DcbTag.query): array<Reventless.DcbTag.tag> => {
  let seen = Set.make()
  let acc = []
  query->Array.forEach(qi =>
    switch qi.tags {
    | None => ()
    | Some(tags) =>
      tags->Array.forEach(tag => {
        let k = `${tag.key}:${tag.value}`
        if !(seen->Set.has(k)) {
          seen->Set.add(k)
          acc->Array.push(tag)
        }
      })
    }
  )
  acc
}

let collectEventTags = (
  events: array<ReventlessCore.DcbEventLog_Adapter.rawStoredEvent>,
): array<Reventless.DcbTag.tag> => {
  let seen = Set.make()
  let acc = []
  events->Array.forEach(event =>
    event.tags->Array.forEach(tag => {
      let k = `${tag.key}:${tag.value}`
      if !(seen->Set.has(k)) {
        seen->Set.add(k)
        acc->Array.push(tag)
      }
    })
  )
  acc
}

// Conditional fence update: a writer may commit only if no one bumped the
// fence past the position the slice observed when building its decision model.
// `after = None` means "no events seen" — the strictest form is
// `attribute_not_exists(lastPosition)`.
let buildConditionalFenceUpdate = (
  tableName: string,
  tag: Reventless.DcbTag.tag,
  ~newPosition: string,
  ~after: option<string>,
): TransactWriteCommand.update => {
  let values = Dict.fromArray([(":new", newPosition->JSON.Encode.string)])
  let conditionExpression = switch after {
  | None => "attribute_not_exists(lastPosition)"
  | Some(pos) =>
    values->Dict.set(":after", pos->JSON.Encode.string)
    "attribute_not_exists(lastPosition) OR lastPosition <= :after"
  }
  {
    TransactWriteCommand.key: fenceKey(tag),
    tableName,
    updateExpression: "SET lastPosition = :new",
    conditionExpression,
    expressionAttributeValues: values,
  }
}

// Unconditional bump — used for tags appearing in new events but not in the
// query. Future readers querying those tags will see the bump and conflict
// against any concurrent writer.
let buildUnconditionalFenceUpdate = (
  tableName: string,
  tag: Reventless.DcbTag.tag,
  ~newPosition: string,
): TransactWriteCommand.update => {
  let values = Dict.fromArray([(":new", newPosition->JSON.Encode.string)])
  {
    TransactWriteCommand.key: fenceKey(tag),
    tableName,
    updateExpression: "SET lastPosition = :new",
    expressionAttributeValues: values,
  }
}

// Read-only fence assertion: verifies no writer bumped the fence past `after`
// WITHOUT advancing it. Used for query tags the slice *reads* but does not
// *partition* by — the read is partition-scoped, so bumping such a tag's fence
// here would falsely conflict every later writer that merely shares the tag
// value (e.g. a second order of the same product). See analysis
// `docs/analysis/dcb-consistency-check-issues.md`.
let buildFenceConditionCheck = (
  tableName: string,
  tag: Reventless.DcbTag.tag,
  ~after: option<string>,
): TransactWriteCommand.conditionCheck =>
  switch after {
  | None => {
      TransactWriteCommand.key: fenceKey(tag),
      tableName,
      conditionExpression: "attribute_not_exists(lastPosition)",
    }
  | Some(pos) => {
      TransactWriteCommand.key: fenceKey(tag),
      tableName,
      conditionExpression: "attribute_not_exists(lastPosition) OR lastPosition <= :after",
      expressionAttributeValues: Dict.fromArray([(":after", pos->JSON.Encode.string)]),
    }
  }

// `TransactWriteItems` is capped at 100 items per call. We surface a clear
// error before calling AWS rather than leaking ValidationException upstream.
let transactWriteItemsLimit = 100

let buildEventPuts = (
  table: resolvedTable,
  events: array<ReventlessCore.DcbEventLog_Adapter.rawStoredEvent>,
  basePosition: string,
  ~partitionTag=?,
) =>
  events->Array.mapWithIndex((event, idx) => {
    let position = generatePositionForBatch(basePosition, idx)
    let recordedAt = ReventlessCore.Message.nowAsISOString()
    let item = toItem(position, event, ~partitionTag?, ~recordedAt)
    let put: TransactWriteCommand.put = {
      TransactWriteCommand.item: item,
      tableName: table.name,
    }
    {TransactWriteCommand.put: put}
  })

let runTransactWrite = async (
  input: TransactWriteCommand.input,
  basePosition: string,
  ~errorPrefix: string,
) =>
  await Effect.tryPromise(~catch=DynamoDb_Error.classify, () => input->TransactWriteCommand.make->TransactWriteCommand.send)
  ->Effect.map(_ => Ok(basePosition))
  ->Effect.catchAll(err =>
    switch err {
    | DynamoDb_Error.StaleState(msg) => Effect.succeed(Error(`Conflict: ${msg}`))
    | Transient(msg) | Permanent(msg) =>
      Effect.succeed(Error(`${errorPrefix}: ${msg}`))
    }
  )
  ->Effect.runPromise

// Writes events without a consistency check but still bumps every event-tag
// fence so concurrent conditional writers cannot miss this commit. The fence
// bumps are unconditional — there is no `after` to check against — but they
// share a single `TransactWriteItems` with the event Puts so the operation is
// atomic. Use this path for imports, seeding, and replay tooling that don't
// need optimistic concurrency but must remain visible to DCB readers.
let appendUnconditional = async (
  table: resolvedTable,
  events: array<ReventlessCore.DcbEventLog_Adapter.rawStoredEvent>,
  ~partitionTag=?,
) => {
  let eventTags = collectEventTags(events)
  let totalItems = events->Array.length + eventTags->Array.length

  if events->Array.length == 0 {
    Ok(generatePosition())
  } else if totalItems > transactWriteItemsLimit {
    Error(
      `DCB append: TransactWriteItems limit exceeded (${totalItems->Int.toString} > ${transactWriteItemsLimit->Int.toString}); reduce events or distinct tag values per command`,
    )
  } else {
    let basePosition = generatePosition()
    let putItems = buildEventPuts(table, events, basePosition, ~partitionTag?)
    let updateItems =
      eventTags->Array.map(tag => {
        TransactWriteCommand.update: buildUnconditionalFenceUpdate(
          table.name,
          tag,
          ~newPosition=basePosition,
        ),
      })
    let input: TransactWriteCommand.input = {
      transactItems: Array.concat(putItems, updateItems),
    }
    await runTransactWrite(input, basePosition, ~errorPrefix="DCB append failed")
  }
}

// The partition tag(s) of a written event — the ONLY fences an append may BUMP.
// A tag's fence must track exactly the partition-scoped events a single-tag read
// of that tag observes (events are stored under `id="<partitionKey>:<value>"`),
// so only the partition tag may advance it. Mirrors `derivePartitionKey`.
//
// For a Composite partition tag there is no single fence key that represents the
// partition, so we keep the historical behaviour (treat every tag as a partition
// tag) rather than risk under-fencing composite-partition slices.
let eventPartitionTags = (
  event: ReventlessCore.DcbEventLog_Adapter.rawStoredEvent,
  ~partitionTag: option<Reventless.DcbTag.derivedPartitionTag>,
): array<Reventless.DcbTag.tag> =>
  switch partitionTag {
  | Some(Composite(_)) => event.tags
  | Some(Simple(pt)) =>
    switch event.tags->Array.find(t => t.key == pt.key) {
    | Some(t) => [t]
    | None => switch event.tags->Array.get(0) {
      | Some(t) => [t]
      | None => []
      }
    }
  | None =>
    switch event.tags->Array.get(0) {
    | Some(t) => [t]
    | None => []
    }
  }

let collectEventPartitionTags = (
  events: array<ReventlessCore.DcbEventLog_Adapter.rawStoredEvent>,
  ~partitionTag: option<Reventless.DcbTag.derivedPartitionTag>,
): array<Reventless.DcbTag.tag> => {
  let seen = Set.make()
  let acc = []
  events->Array.forEach(event =>
    eventPartitionTags(event, ~partitionTag)->Array.forEach(tag => {
      let k = `${tag.key}:${tag.value}`
      if !(seen->Set.has(k)) {
        seen->Set.add(k)
        acc->Array.push(tag)
      }
    })
  )
  acc
}

// Builds the full ordered `TransactWriteItems` array for a conditional append:
// event Puts, then fence Updates (check + bump), then fence ConditionChecks
// (check only), then unconditional bumps. Pure — no IO — so the transaction shape
// is unit-testable without DynamoDB.
let buildConditionalTransactItems = (
  table: resolvedTable,
  events: array<ReventlessCore.DcbEventLog_Adapter.rawStoredEvent>,
  cond: Reventless.DcbTag.appendCondition,
  basePosition: string,
  ~partitionTag: option<Reventless.DcbTag.derivedPartitionTag>=?,
): array<TransactWriteCommand.transactWriteItem> => {
  // The partitions this append writes into — the only fences it may BUMP.
  let partitionTags = collectEventPartitionTags(events, ~partitionTag)
  let partitionKeySet = Set.make()
  partitionTags->Array.forEach(t => partitionKeySet->Set.add(`${t.key}:${t.value}`))
  let isPartition = (t: Reventless.DcbTag.tag) => partitionKeySet->Set.has(`${t.key}:${t.value}`)

  // Distinct tags belonging to multi-tag (composite GSI) query clauses. A composite
  // read can match cross-partition events, so its fences keep the historical
  // check+bump treatment to stay correct.
  let compositeKeySet = Set.make()
  let compositeQueryTags = []
  cond.query->Array.forEach(qi =>
    switch qi.tags {
    | Some(tags) if tags->Array.length > 1 =>
      tags->Array.forEach(tag => {
        let k = `${tag.key}:${tag.value}`
        if !(compositeKeySet->Set.has(k)) {
          compositeKeySet->Set.add(k)
          compositeQueryTags->Array.push(tag)
        }
      })
    | _ => ()
    }
  )
  let isCompositeQueryTag = (t: Reventless.DcbTag.tag) =>
    compositeKeySet->Set.has(`${t.key}:${t.value}`)

  // Classify the conditional fence items per query clause.
  let updateKeySet = Set.make()
  let conditionalUpdateTags = []
  let checkKeySet = Set.make()
  let conditionCheckTags = []
  let pushUpdate = (tag: Reventless.DcbTag.tag) => {
    let k = `${tag.key}:${tag.value}`
    if !(updateKeySet->Set.has(k)) {
      updateKeySet->Set.add(k)
      conditionalUpdateTags->Array.push(tag)
    }
  }
  let pushCheck = (tag: Reventless.DcbTag.tag) => {
    let k = `${tag.key}:${tag.value}`
    if !(checkKeySet->Set.has(k)) {
      checkKeySet->Set.add(k)
      conditionCheckTags->Array.push(tag)
    }
  }

  switch cond.after {
  | Some(_) =>
    cond.query->Array.forEach(qi =>
      switch qi.tags {
      // Single-tag clause = partition-scoped read. The read observes only events
      // in this tag's partition, so its fence may be BUMPED only when this append
      // writes into that partition (conditional Update); otherwise it is asserted
      // read-only (ConditionCheck) so later writers sharing the tag value don't
      // falsely conflict. (Composite-clause tags keep check+bump — see below.)
      | Some([tag]) =>
        if isPartition(tag) || isCompositeQueryTag(tag) {
          pushUpdate(tag)
        } else {
          pushCheck(tag)
        }
      // Multi-tag clause = composite (GSI) read — keep check+bump on every tag.
      | Some(tags) if tags->Array.length > 1 => tags->Array.forEach(pushUpdate)
      | _ => ()
      }
    )
  | None => () // idempotent fallback — no conditional checks; bumps only (below).
  }

  // Unconditional bumps. Advance fences for the partitions this append writes into
  // (so future partition-scoped readers detect it) plus composite query tags (so
  // composite readers detect it), minus anything a conditional Update already
  // bumps. This NEVER bumps secondary (non-partition) event tags — doing so was
  // the source of the cross-partition false conflicts.
  let bumpSeen = Set.make()
  conditionalUpdateTags->Array.forEach(t => bumpSeen->Set.add(`${t.key}:${t.value}`))
  let bumpTags = []
  let candidateBumps = switch cond.after {
  | Some(_) => partitionTags
  | None => Array.concat(partitionTags, compositeQueryTags)
  }
  candidateBumps->Array.forEach(tag => {
    let k = `${tag.key}:${tag.value}`
    if !(bumpSeen->Set.has(k)) {
      bumpSeen->Set.add(k)
      bumpTags->Array.push(tag)
    }
  })

  let putItems = buildEventPuts(table, events, basePosition, ~partitionTag?)
  let updateItems =
    conditionalUpdateTags->Array.map(tag => {
      TransactWriteCommand.update: buildConditionalFenceUpdate(
        table.name,
        tag,
        ~newPosition=basePosition,
        ~after=cond.after,
      ),
    })
  let checkItems =
    conditionCheckTags->Array.map(tag => {
      TransactWriteCommand.conditionCheck: buildFenceConditionCheck(table.name, tag, ~after=cond.after),
    })
  let bumpItems =
    bumpTags->Array.map(tag => {
      TransactWriteCommand.update: buildUnconditionalFenceUpdate(table.name, tag, ~newPosition=basePosition),
    })

  Array.concat(putItems, Array.concat(updateItems, Array.concat(checkItems, bumpItems)))
}

let appendConditional = async (
  table: resolvedTable,
  events: array<ReventlessCore.DcbEventLog_Adapter.rawStoredEvent>,
  cond: Reventless.DcbTag.appendCondition,
  ~partitionTag=?,
) => {
  let queryTags = collectQueryTags(cond.query)

  if queryTags->Array.length == 0 {
    Error(
      "DCB append: tagless conditions are not supported on DynamoDB — every queryItem must have at least one tag",
    )
  } else {
    let basePosition = generatePosition()
    let transactItems = buildConditionalTransactItems(table, events, cond, basePosition, ~partitionTag?)
    let totalItems = transactItems->Array.length
    if totalItems > transactWriteItemsLimit {
      Error(
        `DCB append: TransactWriteItems limit exceeded (${totalItems->Int.toString} > ${transactWriteItemsLimit->Int.toString}); reduce events or distinct tag values per command`,
      )
    } else {
      let input: TransactWriteCommand.input = {transactItems: transactItems}
      await runTransactWrite(input, basePosition, ~errorPrefix="DCB append failed")
    }
  }
}

let append = (table: resolvedTable, ~partitionTag=?) =>
  async (
    events: array<ReventlessCore.DcbEventLog_Adapter.rawStoredEvent>,
    ~condition=?,
  ) => {
    switch condition {
    | None => await appendUnconditional(table, events, ~partitionTag?)
    | Some(cond) => await appendConditional(table, events, cond, ~partitionTag?)
    }
  }

// --- Stream Query Operations (lazy pagination via Stream.paginateEffect) ---

let queryByPartitionKeyStream = (
  table: resolvedTable,
  partitionKey: string,
  ~after: option<string>=?,
  ~strongConsistency: bool=false,
) => {
  let baseParams = buildQueryByPartitionKeyInput(
    table,
    partitionKey,
    ~after?,
    ~strongConsistency,
  )
  Stream.paginateEffect((None: option<dict<JSON.t>>), cursor =>
    Effect.tryPromise(
      ~catch=DynamoDb_Error.classify,
      () => {
        let params = switch cursor {
        | None => baseParams
        | Some(key) => {...baseParams, exclusiveStartKey: key}
        }
        QueryCommand.send(params->QueryCommand.make)
      },
    )
    ->Effect.retry(DynamoDb_Error.retrySchedule)
    ->Effect.catchAll(err => Effect.fail(DynamoDb_Error.message(err)))
    ->Effect.map(result => (
      result.items->Option.getOr([]),
      result.lastEvaluatedKey->Option.map(key => Some(key)),
    ))
  )
}

let queryBySingleTagStream = (
  table: resolvedTable,
  tagKey: string,
  tagValue: string,
  ~after: option<string>=?,
) => {
  let indexName = tagToAttributeName(tagKey)
  let expressionAttributeValues = Dict.fromArray([(":val", tagValue->JSON.Encode.string)])
  let (keyConditionExpression, expressionAttributeNames) = switch after {
  | None => (`${indexName} = :val`, None)
  | Some(afterPos) => {
      expressionAttributeValues->Dict.set(":after", afterPos->JSON.Encode.string)
      (`${indexName} = :val AND #pos > :after`, Some(Dict.fromArray([("#pos", "position")])))
    }
  }
  let baseParams: QueryCommand.input = {
    tableName: table.name,
    indexName: indexName,
    keyConditionExpression: keyConditionExpression,
    expressionAttributeValues: expressionAttributeValues,
    ?expressionAttributeNames,
  }
  Stream.paginateEffect((None: option<dict<JSON.t>>), cursor =>
    Effect.tryPromise(
      ~catch=DynamoDb_Error.classify,
      () => {
        let params = switch cursor {
        | None => baseParams
        | Some(key) => {...baseParams, exclusiveStartKey: key}
        }
        QueryCommand.send(params->QueryCommand.make)
      },
    )
    ->Effect.retry(DynamoDb_Error.retrySchedule)
    ->Effect.catchAll(err => Effect.fail(DynamoDb_Error.message(err)))
    ->Effect.map(result => (
      result.items->Option.getOr([]),
      result.lastEvaluatedKey->Option.map(key => Some(key)),
    ))
  )
}

let queryByCompositeTagsStream = (
  table: resolvedTable,
  tags: array<Reventless.DcbTag.tag>,
  ~after: option<string>=?,
) => {
  let composite = compositeTagKey(tags)
  let expressionAttributeValues = Dict.fromArray([
    (":composite", composite->JSON.Encode.string),
  ])
  let (keyConditionExpression, expressionAttributeNames) = switch after {
  | None => ("tag_composite = :composite", None)
  | Some(afterPos) => {
      expressionAttributeValues->Dict.set(":after", afterPos->JSON.Encode.string)
      ("tag_composite = :composite AND #pos > :after", Some(Dict.fromArray([("#pos", "position")])))
    }
  }
  let baseParams: QueryCommand.input = {
    tableName: table.name,
    indexName: "tag_composite",
    keyConditionExpression: keyConditionExpression,
    expressionAttributeValues: expressionAttributeValues,
    ?expressionAttributeNames,
  }
  Stream.paginateEffect((None: option<dict<JSON.t>>), cursor =>
    Effect.tryPromise(
      ~catch=DynamoDb_Error.classify,
      () => {
        let params = switch cursor {
        | None => baseParams
        | Some(key) => {...baseParams, exclusiveStartKey: key}
        }
        QueryCommand.send(params->QueryCommand.make)
      },
    )
    ->Effect.retry(DynamoDb_Error.retrySchedule)
    ->Effect.catchAll(err => Effect.fail(DynamoDb_Error.message(err)))
    ->Effect.map(result => (
      result.items->Option.getOr([]),
      result.lastEvaluatedKey->Option.map(key => Some(key)),
    ))
  )
}

let scanWithFilterStream = (
  table: resolvedTable,
  ~eventTypes: option<array<string>>=?,
  ~after: option<string>=?,
) => {
  let expressionAttributeValues = Dict.make()
  let expressionAttributeNames = Dict.make()
  let filterParts = []

  switch eventTypes {
  | None => ()
  | Some(types) => {
      expressionAttributeNames->Dict.set("#evt", "event")
      let typeConditions = types->Array.mapWithIndex((typ, idx) => {
        let placeholder = `:type${idx->Int.toString}`
        expressionAttributeValues->Dict.set(placeholder, typ->JSON.Encode.string)
        `#evt = ${placeholder}`
      })
      filterParts->Array.push(`(${typeConditions->Array.join(" OR ")})`)
    }
  }

  let filterExpression = if filterParts->Array.length > 0 {
    Some(filterParts->Array.join(" AND "))
  } else {
    None
  }

  let hasAttributeValues = expressionAttributeValues->Dict.keysToArray->Array.length > 0
  let hasAttributeNames = expressionAttributeNames->Dict.keysToArray->Array.length > 0

  let baseParams: ScanCommand.input = {
    tableName: table.name,
    ?filterExpression,
    expressionAttributeValues: ?(hasAttributeValues ? Some(expressionAttributeValues) : None),
    expressionAttributeNames: ?(hasAttributeNames ? Some(expressionAttributeNames) : None),
  }

  // position cannot appear in FilterExpression (it is the table's sort key).
  // Filter by position in application code after each page is fetched.
  let baseStream = Stream.paginateEffect((None: option<dict<JSON.t>>), cursor =>
    Effect.tryPromise(
      ~catch=DynamoDb_Error.classify,
      () => {
        let params = switch cursor {
        | None => baseParams
        | Some(key) => {...baseParams, exclusiveStartKey: key}
        }
        ScanCommand.send(ScanCommand.make(params))
      },
    )
    ->Effect.retry(DynamoDb_Error.retrySchedule)
    ->Effect.catchAll(err => Effect.fail(DynamoDb_Error.message(err)))
    ->Effect.map(result => (
      result.items->Option.getOr([]),
      result.lastEvaluatedKey->Option.map(key => Some(key)),
    ))
  )

  switch after {
  | None => baseStream
  | Some(afterPos) =>
    baseStream->Stream.filter(item =>
      item
      ->JSON.Decode.object
      ->Option.flatMap(obj => obj->Dict.get("position"))
      ->Option.flatMap(JSON.Decode.string)
      ->Option.mapOr(false, pos => String.compare(pos, afterPos) > 0.)
    )
  }
}

let executeQueryItemStream = (
  table: resolvedTable,
  queryItem: Reventless.DcbTag.queryItem,
  ~after: option<string>=?,
) => {
  switch queryItem.tags {
  // Single tag: direct partition key lookup. Base-table reads support strong
  // consistency, which the slice's decision-model read needs to avoid stale
  // events that would otherwise force an avoidable fence-conflict retry.
  // GSI-backed branches (composite, scan) cannot opt in — fundamental
  // DynamoDB constraint — so they stay eventually consistent.
  | Some([tag]) =>
    queryByPartitionKeyStream(
      table,
      `${tag.key}:${tag.value}`,
      ~after?,
      ~strongConsistency=true,
    )

  // Multiple tags: use composite GSI
  | Some(tags) if tags->Array.length > 1 =>
    queryByCompositeTagsStream(table, tags, ~after?)

  // No tags (or empty): fall back to scan
  | None | Some([]) | Some(_) =>
    switch queryItem.eventTypes {
    | Some(eventTypes) => scanWithFilterStream(table, ~eventTypes, ~after?)
    | None => scanWithFilterStream(table, ~after?)
    }
  }
}

let readStream = (table: resolvedTable) =>
  (~query: Reventless.DcbTag.query, ~after=?) => {
    let streams = query->Array.map(qi => executeQueryItemStream(table, qi, ~after?))
    switch streams->Array.length {
    | 0 => Stream.empty
    | 1 => (streams->Array.getUnsafe(0))->Stream.map(fromItem)
    | _ =>
      // Scan sub-queries (tags = None) return items in unspecified order, so
      // a lazy k-way merge is not possible. Fall back to eager collect + sort.
      let hasScan = query->Array.some(qi => qi.tags == None)
      if hasScan {
        streams
        ->Array.map(s => s->Stream.runCollect)
        ->Effect.all({"concurrency": 3})
        ->Effect.map(results => {
          let allItems = results->Array.flat->Array.map(fromItem)
          let deduped = deduplicateByPosition(allItems)
          deduped->Array.toSorted((a, b) => String.compare(a.position, b.position))
        })
        ->Stream.fromEffect
        ->Stream.flatMap(events => Stream.fromIterable(events))
      } else {
        // All sub-streams are tag-based GSI queries — items arrive in position
        // order (rangeKey = "position"). Merge lazily: DynamoDB pages are only
        // fetched as the consumer requests more elements.
        mergeSortedEvents(streams->Array.map(s => s->Stream.map(fromItem)))
        ->dedupByPosition
      }
    }
  }
