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

// --- Item Conversion ---

let toItem = (position: string, event: ReventlessCore.DcbEventLog_Adapter.rawStoredEvent): JSON.t => {
  // Create base item
  let item = Dict.make()
  // Use "id" with value "dcb" for single partition (required by Util_DynamoDb table structure)
  item->Dict.set("id", "dcb"->JSON.Encode.string)
  item->Dict.set("position", position->JSON.Encode.string)
  item->Dict.set("eventType", event.eventType->JSON.Encode.string)
  item->Dict.set("data", event.data)

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
    ->Dict.get("eventType")
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

    {
      position,
      eventType,
      data,
      tags,
    }
  }
}

// --- Query Operations ---

let queryBySingleTag = async (
  table: runtimeTable,
  tagKey: string,
  tagValue: string,
  ~after: option<string>=?,
) => {
  let indexName = tagToAttributeName(tagKey)
  let keyConditionExpression = `${indexName} = :val`

  let expressionAttributeValues = Dict.fromArray([
    (":val", tagValue->JSON.Encode.string),
  ])

  let (filterExpression, expressionAttributeNames) = switch after {
  | None => (None, None)
  | Some(afterPos) => {
      expressionAttributeValues->Dict.set(":after", afterPos->JSON.Encode.string)
      (Some("#pos > :after"), Some(Dict.fromArray([("#pos", "position")])))
    }
  }

  let queryParams: QueryCommand.input = {
    tableName: table.name,
    indexName: indexName,
    keyConditionExpression: keyConditionExpression,
    expressionAttributeValues: expressionAttributeValues,
    ?filterExpression,
    ?expressionAttributeNames,
  }

  await queryStream(queryParams)->Stream.runCollect->Effect.runPromise
}

let queryByCompositeTags = async (
  table: runtimeTable,
  tags: array<Reventless.DcbTag.tag>,
  ~after: option<string>=?,
) => {
  let composite = compositeTagKey(tags)
  let indexName = "tag_composite"
  let keyConditionExpression = "tag_composite = :composite"

  let expressionAttributeValues = Dict.fromArray([
    (":composite", composite->JSON.Encode.string),
  ])

  let (filterExpression, expressionAttributeNames) = switch after {
  | None => (None, None)
  | Some(afterPos) => {
      expressionAttributeValues->Dict.set(":after", afterPos->JSON.Encode.string)
      (Some("#pos > :after"), Some(Dict.fromArray([("#pos", "position")])))
    }
  }

  let queryParams: QueryCommand.input = {
    tableName: table.name,
    indexName: indexName,
    keyConditionExpression: keyConditionExpression,
    expressionAttributeValues: expressionAttributeValues,
    ?filterExpression,
    ?expressionAttributeNames,
  }

  await queryStream(queryParams)->Stream.runCollect->Effect.runPromise
}

let scanWithFilter = async (
  table: runtimeTable,
  ~eventTypes: option<array<string>>=?,
  ~after: option<string>=?,
) => {
  let expressionAttributeValues = Dict.make()
  let expressionAttributeNames = Dict.make()

  let filterParts = []

  // Add eventType filter
  switch eventTypes {
  | None => ()
  | Some(types) => {
      let typeConditions = types->Array.mapWithIndex((typ, idx) => {
        let placeholder = `:type${idx->Int.toString}`
        expressionAttributeValues->Dict.set(placeholder, typ->JSON.Encode.string)
        `eventType = ${placeholder}`
      })
      filterParts->Array.push(`(${typeConditions->Array.join(" OR ")})`)
    }
  }

  // Add position filter
  switch after {
  | None => ()
  | Some(afterPos) => {
      expressionAttributeNames->Dict.set("#pos", "position")
      expressionAttributeValues->Dict.set(":after", afterPos->JSON.Encode.string)
      filterParts->Array.push("#pos > :after")
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

  await scanStream(scanParams)->Stream.runCollect->Effect.runPromise
}

// --- Query Item Execution ---

let executeQueryItem = async (
  table: runtimeTable,
  queryItem: Reventless.DcbTag.queryItem,
  ~after: option<string>=?,
) => {
  switch queryItem.tags {
  // Single tag: use single-tag GSI
  | Some([tag]) =>
    await queryBySingleTag(table, tag.key, tag.value, ~after?)

  // Multi-tag: use composite GSI
  | Some(tags) =>
    // Array has 2+ elements
    await queryByCompositeTags(table, tags, ~after?)

  // Empty or no tags: check event types
  | None =>
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

let read = (table: runtimeTable) =>
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

let writeEventsWithPosition = async (
  table: runtimeTable,
  events: array<ReventlessCore.DcbEventLog_Adapter.rawStoredEvent>,
  basePosition: string,
) => {
  let items = events->Array.mapWithIndex((event, idx) => {
    let position = generatePositionForBatch(basePosition, idx)
    toItem(position, event)
  })

  switch await items
  ->Array.map(toPutRequest)
  ->toTable(table.name)
  ->batchWriteWithRetries {
  | Ok() => Ok()
  | Error(msg) => Error(msg)
  }
}

let append = (table: runtimeTable) =>
  async (
    events: array<ReventlessCore.DcbEventLog_Adapter.rawStoredEvent>,
    ~condition=?,
  ) => {
    switch condition {
    | None => {
        // Unconditional append
        let position = generatePosition()
        switch await writeEventsWithPosition(table, events, position) {
        | Ok() => Ok(position)
        | Error(msg) => Error(msg)
        }
      }

    | Some(cond: Reventless.DcbTag.appendCondition) => {
        // Conditional append: check for conflicts first
        let readResult = await read(table)(~query=cond.query, ~after=?cond.after)

        if readResult.events->Array.length > 0 {
          // Conflict detected
          Error("Conflict: matching events exist after specified position")
        } else {
          // No conflicts, proceed with append
          let position = generatePosition()
          switch await writeEventsWithPosition(table, events, position) {
          | Ok() => Ok(position)
          | Error(msg) => Error(msg)
          }
        }
      }
    }
  }

// --- Stream Query Operations (lazy pagination via Stream.paginateEffect) ---

let queryBySingleTagStream = (
  table: runtimeTable,
  tagKey: string,
  tagValue: string,
  ~after: option<string>=?,
) => {
  let indexName = tagToAttributeName(tagKey)
  let expressionAttributeValues = Dict.fromArray([(":val", tagValue->JSON.Encode.string)])
  let (filterExpression, expressionAttributeNames) = switch after {
  | None => (None, None)
  | Some(afterPos) => {
      expressionAttributeValues->Dict.set(":after", afterPos->JSON.Encode.string)
      (Some("#pos > :after"), Some(Dict.fromArray([("#pos", "position")])))
    }
  }
  let baseParams: QueryCommand.input = {
    tableName: table.name,
    indexName: indexName,
    keyConditionExpression: `${indexName} = :val`,
    expressionAttributeValues: expressionAttributeValues,
    ?filterExpression,
    ?expressionAttributeNames,
  }
  Stream.paginateEffect((None: option<dict<JSON.t>>), cursor =>
    Effect.tryPromise(
      ~catch=err =>
        (err->Obj.magic: JsExn.t)->JsExn.message->Option.getOr("queryBySingleTagStream error"),
      () => {
        let params = switch cursor {
        | None => baseParams
        | Some(key) => {...baseParams, exclusiveStartKey: key}
        }
        QueryCommand.send(params->QueryCommand.make)
      },
    )
    ->Effect.map(result => (
      result.items->Option.getOr([]),
      result.lastEvaluatedKey->Option.map(key => Some(key)),
    ))
  )
}

let queryByCompositeTagsStream = (
  table: runtimeTable,
  tags: array<Reventless.DcbTag.tag>,
  ~after: option<string>=?,
) => {
  let composite = compositeTagKey(tags)
  let expressionAttributeValues = Dict.fromArray([
    (":composite", composite->JSON.Encode.string),
  ])
  let (filterExpression, expressionAttributeNames) = switch after {
  | None => (None, None)
  | Some(afterPos) => {
      expressionAttributeValues->Dict.set(":after", afterPos->JSON.Encode.string)
      (Some("#pos > :after"), Some(Dict.fromArray([("#pos", "position")])))
    }
  }
  let baseParams: QueryCommand.input = {
    tableName: table.name,
    indexName: "tag_composite",
    keyConditionExpression: "tag_composite = :composite",
    expressionAttributeValues: expressionAttributeValues,
    ?filterExpression,
    ?expressionAttributeNames,
  }
  Stream.paginateEffect((None: option<dict<JSON.t>>), cursor =>
    Effect.tryPromise(
      ~catch=err =>
        (err->Obj.magic: JsExn.t)
        ->JsExn.message
        ->Option.getOr("queryByCompositeTagsStream error"),
      () => {
        let params = switch cursor {
        | None => baseParams
        | Some(key) => {...baseParams, exclusiveStartKey: key}
        }
        QueryCommand.send(params->QueryCommand.make)
      },
    )
    ->Effect.map(result => (
      result.items->Option.getOr([]),
      result.lastEvaluatedKey->Option.map(key => Some(key)),
    ))
  )
}

let scanWithFilterStream = (
  table: runtimeTable,
  ~eventTypes: option<array<string>>=?,
  ~after: option<string>=?,
) => {
  let expressionAttributeValues = Dict.make()
  let expressionAttributeNames = Dict.make()
  let filterParts = []

  switch eventTypes {
  | None => ()
  | Some(types) => {
      let typeConditions = types->Array.mapWithIndex((typ, idx) => {
        let placeholder = `:type${idx->Int.toString}`
        expressionAttributeValues->Dict.set(placeholder, typ->JSON.Encode.string)
        `eventType = ${placeholder}`
      })
      filterParts->Array.push(`(${typeConditions->Array.join(" OR ")})`)
    }
  }

  switch after {
  | None => ()
  | Some(afterPos) => {
      expressionAttributeNames->Dict.set("#pos", "position")
      expressionAttributeValues->Dict.set(":after", afterPos->JSON.Encode.string)
      filterParts->Array.push("#pos > :after")
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

  Stream.paginateEffect((None: option<dict<JSON.t>>), cursor =>
    Effect.tryPromise(
      ~catch=err =>
        (err->Obj.magic: JsExn.t)->JsExn.message->Option.getOr("scanWithFilterStream error"),
      () => {
        let params = switch cursor {
        | None => baseParams
        | Some(key) => {...baseParams, exclusiveStartKey: key}
        }
        ScanCommand.send(ScanCommand.make(params))
      },
    )
    ->Effect.map(result => (
      result.items->Option.getOr([]),
      result.lastEvaluatedKey->Option.map(key => Some(key)),
    ))
  )
}

let executeQueryItemStream = (
  table: runtimeTable,
  queryItem: Reventless.DcbTag.queryItem,
  ~after: option<string>=?,
) =>
  switch queryItem.tags {
  | Some([tag]) =>
    queryBySingleTagStream(table, tag.key, tag.value, ~after?)
  | Some(tags) =>
    queryByCompositeTagsStream(table, tags, ~after?)
  | None =>
    switch queryItem.eventTypes {
    | Some(eventTypes) => scanWithFilterStream(table, ~eventTypes, ~after?)
    | None => scanWithFilterStream(table, ~after?)
    }
  }

let readStream = (table: runtimeTable) =>
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
