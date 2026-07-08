open Util_DynamoDb_Runtime
open AwsSdk.DynamoDb.DocumentClient

// --- Position Generation ---

// Hybrid-logical-clock minimal variant. The module-level refs live for the life of
// a warm Lambda container (reset on cold start), giving strictly-monotonic positions
// per call WITHIN a container: same-millisecond calls increment `counter`; a forward
// tick resets it to 0. No cross-container coordination — two same-ms writers on
// different containers both start at counter 0 and are ordered by the UUID tiebreaker
// (best-effort, exactly as the old `<ms>-<uuid>` format was). Format:
// `<ms>-<6-digit counter>-<uuid>`. Correctness never depends on this — fence
// comparisons anchor to what a slice observed, and `TransactWriteItems` serialises
// commits; this only makes reader/replay ordering predictable per container. Old
// `<ms>-<uuid>` positions remain valid: the ms prefix keeps the same 13-digit width,
// so cross-format comparison still orders by timestamp. See
// docs/plans/done/dcb-monotonic-position-generation.md.
let lastMs = ref(0.0)
let counter = ref(0)

let generatePosition = () => {
  let now = Date.make()->Date.getTime
  if now == lastMs.contents {
    counter := counter.contents + 1
  } else {
    lastMs := now
    counter := 0
  }
  let ms = now->Float.toString
  let counterStr = counter.contents->Int.toString->String.padStart(6, "0")
  let uuid = Uuid.v4()
  `${ms}-${counterStr}-${uuid}`
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

// GSI projection policy (consumed by the deploy-time `make`): only the
// composite-tag GSI keeps a full (`ALL`) projection, because composite decision
// reads resolve events directly from it. The per-tag `tag_<key>` GSIs are
// `KEYS_ONLY` — no reader today, and Phase 7's cross-partition read goes
// `Query`(keys) → `BatchGetItem`(payloads). Pure predicate so it is unit-testable
// without the Pulumi deploy layer. See docs/plans/dcb-consistency-hardening.md Phase 3.
let compositeIndexName = "tag_composite"
let indexKeepsFullProjection = (indexName: string): bool => indexName == compositeIndexName

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

  // Add composite tag attribute if multiple tags. The tag set here is exactly the
  // event's *entity* tags (no framework provenance tag is smuggled in — see
  // docs/plans/done/dcb-composite-query-clause-fence-contention.md), so the stored
  // `tag_composite` key is byte-identical to the key a composite decision read
  // builds from the command's entity tags — the write/read match a composite
  // slice's OCC depends on.
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

// Filter clause shared by both scan paths.
type scanFilter = {
  filterExpression: option<string>,
  expressionAttributeNames: option<Dict.t<string>>,
  expressionAttributeValues: option<Dict.t<JSON.t>>,
}

// Builds the scan FilterExpression. Always asserts `attribute_exists(event)` so
// `fence#…` sentinels — which carry no `event`/`data` attributes and would make
// `fromItem` throw — are never returned, regardless of whether an event-type
// filter is present (Issue 12). A non-empty `eventTypes` adds the usual type
// disjunction on top; an absent or empty list leaves just the fence guard
// (avoids emitting a degenerate empty `()` group).
let buildScanFilter = (~eventTypes: option<array<string>>=?): scanFilter => {
  let expressionAttributeValues = Dict.make()
  let expressionAttributeNames = Dict.fromArray([("#evt", "event")])
  let filterParts = ["attribute_exists(#evt)"]

  switch eventTypes {
  | None | Some([]) => ()
  | Some(types) =>
    let typeConditions = types->Array.mapWithIndex((typ, idx) => {
      let placeholder = `:type${idx->Int.toString}`
      expressionAttributeValues->Dict.set(placeholder, typ->JSON.Encode.string)
      `#evt = ${placeholder}`
    })
    filterParts->Array.push(`(${typeConditions->Array.join(" OR ")})`)
  }

  let hasAttributeValues = expressionAttributeValues->Dict.keysToArray->Array.length > 0
  {
    filterExpression: Some(filterParts->Array.join(" AND ")),
    expressionAttributeNames: Some(expressionAttributeNames),
    expressionAttributeValues: hasAttributeValues ? Some(expressionAttributeValues) : None,
  }
}

let scanWithFilter = async (
  table: resolvedTable,
  ~eventTypes: option<array<string>>=?,
  ~after: option<string>=?,
) => {
  let filter = buildScanFilter(~eventTypes?)

  let scanParams: ScanCommand.input = {
    tableName: table.name,
    filterExpression: ?filter.filterExpression,
    expressionAttributeValues: ?filter.expressionAttributeValues,
    expressionAttributeNames: ?filter.expressionAttributeNames,
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

// --- Cross-partition (secondary-tag) read ---
//
// A `@crossPartition` tag is read across ALL partitions carrying it, not just
// the partition it keys. The per-tag `tag_<key>` GSI indexes the tag across
// every partition; Phase 3 down-projected it to `KEYS_ONLY`, so the read is a
// two-phase `Query`(keys: id, position) → per-key `GetItem`(base table) for the
// full event. GSI reads are eventually consistent (DynamoDB constraint) — the
// strongly-consistent append fence catches any staleness at commit (analysis
// Issue 13). The GSI returns keys in ascending `position` order (rangeKey =
// "position"), and `Stream.mapEffect` preserves order, so the resolved stream
// stays position-ordered for the k-way merge in `readStream`.

// Resolves a KEYS_ONLY GSI key-item ({id, position}) to its full base-table item.
let resolveBaseItem = (table: resolvedTable, keyItem: JSON.t): Effect.t<
  option<JSON.t>,
  string,
  unit,
> =>
  switch keyItem->JSON.Decode.object {
  | None => Effect.succeed(None)
  | Some(obj) =>
    switch (obj->Dict.get("id"), obj->Dict.get("position")) {
    | (Some(id), Some(position)) =>
      let key = Dict.fromArray([("id", id), ("position", position)])
      Effect.tryPromise(~catch=DynamoDb_Error.classify, () =>
        GetCommand.send(GetCommand.make({tableName: table.name, key}))
      )
      ->Effect.retry(DynamoDb_Error.retrySchedule)
      ->Effect.catchAll(err => Effect.fail(DynamoDb_Error.message(err)))
      ->Effect.map(result => result.item)
    | _ => Effect.succeed(None)
    }
  }

let queryBySingleTagCrossPartitionStream = (
  table: resolvedTable,
  tag: Reventless.DcbTag.tag,
  ~after: option<string>=?,
) => {
  let indexName = tagToAttributeName(tag.key)
  let expressionAttributeValues = Dict.fromArray([(":val", tag.value->JSON.Encode.string)])
  let expressionAttributeNames = Dict.fromArray([("#tag", indexName)])
  let keyConditionExpression = switch after {
  | None => "#tag = :val"
  | Some(afterPos) =>
    expressionAttributeValues->Dict.set(":after", afterPos->JSON.Encode.string)
    expressionAttributeNames->Dict.set("#pos", "position")
    "#tag = :val AND #pos > :after"
  }
  let baseParams: QueryCommand.input = {
    tableName: table.name,
    indexName,
    keyConditionExpression,
    expressionAttributeValues,
    expressionAttributeNames,
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
  ->Stream.mapEffect(keyItem => resolveBaseItem(table, keyItem))
  ->Stream.flatMap(opt =>
    switch opt {
    | Some(item) => Stream.fromIterable([item])
    | None => Stream.empty
    }
  )
}

// --- Query Item Execution ---

let executeQueryItem = async (
  table: resolvedTable,
  queryItem: Reventless.DcbTag.queryItem,
  ~after: option<string>=?,
  ~crossPartitionTagKeys: array<string>=[],
) => {
  switch queryItem.tags {
  // Single tag: a `@crossPartition` key reads across partitions via the per-tag
  // GSI (KEYS_ONLY → per-key GetItem, collected); otherwise a base-table
  // partition lookup.
  | Some([tag]) if crossPartitionTagKeys->Array.includes(tag.key) =>
    await queryBySingleTagCrossPartitionStream(table, tag, ~after?)
    ->Stream.runCollect
    ->Effect.runPromise
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

let read = (table: resolvedTable, ~crossPartitionTagKeys: array<string>=[]) =>
  async (
    ~query: Reventless.DcbTag.query,
    ~after=?,
  ) => {
    // Execute queries for each queryItem
    let queryResults = await query
    ->Array.map(queryItem => executeQueryItem(table, queryItem, ~after?, ~crossPartitionTagKeys))
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
// A fence is a sentinel item in the same table holding one position attribute PER
// EVENT TYPE — `pos#<eventType>` — instead of a single scalar. Each tag value
// (`<key>:<value>`) gets its own fence at `id = "fence#<key>:<value>", position =
// "FENCE"`. The id prefix is distinct from event partition keys (`<key>:<value>`),
// so event reads never see fence items.
//
// On conditional append, each query tag becomes a per-type `ConditionalUpdate` or
// read-only `ConditionCheck`: it asserts that no event OF A TYPE THE SLICE READS
// (`pos#<consumedType>`) has advanced past `after` since the decision-model read,
// and advances `pos#<producedType>` for the types it writes. Because the check is
// scoped to the consumed types, a slice reading only a SUBSET of a partition's
// event types no longer false-conflicts when a sibling type advances (analysis
// Issue 4); the OCC now mirrors the local backends' true query semantics. At
// `after=None` the partition-tag Update is gated on `attribute_not_exists(pos#…)`
// over the consumed ∪ produced types — the FOLDED CREATE GUARD that serializes
// concurrent first-writers (replacing the old `create#…` sentinel rows).
//
// All Puts and Updates ride a single `TransactWriteItems` call — atomic by
// DynamoDB. Conflicts surface as `TransactionCanceledException` →
// `DynamoDb_Error.StaleState` → `Error(DcbEventLog.Conflict)`.

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

// Per-event-type fence attributes. The fence sentinel holds one position
// attribute per event type — `pos#<eventType>` — instead of a single scalar
// `lastPosition`. This lets the OCC check mirror the read query's event-type
// filter: a slice reading only a subset of a partition's event types conflicts
// only when an event *of a type it reads* advances past its `after`, matching the
// local backends' true DCB query semantics (and fixing analysis Issue 4 — the
// one-event-type-per-attribute deadlock). It also folds the create guard into the
// fence (see `buildConditionalFenceUpdate`), retiring the `create#` rows.
// Plan: docs/plans/dcb-fence-event-type-granularity.md.
let fenceTypeAttr = (eventType: string) => `pos#${eventType}`

let dedupStrings = (xs: array<string>): array<string> => {
  let seen = Set.make()
  xs->Array.filter(x =>
    if seen->Set.has(x) {
      false
    } else {
      seen->Set.add(x)
      true
    }
  )
}

// tagKey ("key:value") -> distinct event types among `events` that CARRY the tag.
// Used to advance the fences of composite query tags and cross-partition tags
// (bumped by every carrier), and by `appendUnconditional`.
let carriedTypesByTag = (
  events: array<ReventlessCore.DcbEventLog_Adapter.rawStoredEvent>,
): Dict.t<array<string>> => {
  let d = Dict.make()
  events->Array.forEach(e =>
    e.tags->Array.forEach((t: Reventless.DcbTag.tag) => {
      let k = `${t.key}:${t.value}`
      let cur = d->Dict.get(k)->Option.getOr([])
      if !(cur->Array.includes(e.eventType)) {
        d->Dict.set(k, cur->Array.concat([e.eventType]))
      }
    })
  )
  d
}

// Conditional fence update with per-type granularity AND a folded create guard:
//  - `producedTypes`: event types this append writes into the tag's partition; each
//    `pos#<type>` is advanced to `newPosition`.
//  - `consumedTypes`: event types the slice reads on this tag — the OCC check scope.
//  - `after = Some(p)`: assert each consumed type's position has not advanced past
//    `p` (`attribute_not_exists(pos#C) OR pos#C <= :after`).
//  - `after = None`: the folded create guard — assert `attribute_not_exists` over
//    every consumed AND produced type, so two concurrent first-writers of the same
//    `(producedType, partition)` collide and only one commits. The produced arm
//    guards against a double-create even when the produced type is not consumed and
//    must NEVER be dropped (it replaces the old `create#` sentinel row).
let buildConditionalFenceUpdate = (
  tableName: string,
  tag: Reventless.DcbTag.tag,
  ~consumedTypes: array<string>,
  ~producedTypes: array<string>,
  ~newPosition: string,
  ~after: option<string>,
): TransactWriteCommand.update => {
  let names = Dict.make()
  let values = Dict.fromArray([(":new", newPosition->JSON.Encode.string)])

  let setClauses = producedTypes->Array.mapWithIndex((pt, i) => {
    let ph = `#p${i->Int.toString}`
    names->Dict.set(ph, fenceTypeAttr(pt))
    `${ph} = :new`
  })

  let conditionExpression = switch after {
  | None =>
    dedupStrings(Array.concat(consumedTypes, producedTypes))
    ->Array.mapWithIndex((t, i) => {
      let ph = `#c${i->Int.toString}`
      names->Dict.set(ph, fenceTypeAttr(t))
      `attribute_not_exists(${ph})`
    })
    ->Array.join(" AND ")
  | Some(pos) =>
    values->Dict.set(":after", pos->JSON.Encode.string)
    // A real append condition always carries the consumed types (buildQueryFromCommand
    // sets them). Fall back to the produced types if a caller omits them, so the
    // conditional Update never degenerates to an empty condition expression.
    let checkTypes = consumedTypes->Array.length == 0 ? producedTypes : consumedTypes
    checkTypes
    ->Array.mapWithIndex((t, i) => {
      let ph = `#c${i->Int.toString}`
      names->Dict.set(ph, fenceTypeAttr(t))
      `(attribute_not_exists(${ph}) OR ${ph} <= :after)`
    })
    ->Array.join(" AND ")
  }

  {
    TransactWriteCommand.key: fenceKey(tag),
    tableName,
    updateExpression: `SET ${setClauses->Array.join(", ")}`,
    conditionExpression,
    expressionAttributeNames: names,
    expressionAttributeValues: values,
  }
}

// Unconditional per-type bump — used for tags appearing in new events but not gated
// by this append (composite query tags, cross-partition carriers, replay/seed). Each
// produced type's `pos#<type>` is advanced so future readers querying that tag detect
// the commit and conflict against any concurrent writer; no condition.
let buildUnconditionalFenceUpdate = (
  tableName: string,
  tag: Reventless.DcbTag.tag,
  ~producedTypes: array<string>,
  ~newPosition: string,
): TransactWriteCommand.update => {
  let names = Dict.make()
  let values = Dict.fromArray([(":new", newPosition->JSON.Encode.string)])
  let setClauses = producedTypes->Array.mapWithIndex((pt, i) => {
    let ph = `#p${i->Int.toString}`
    names->Dict.set(ph, fenceTypeAttr(pt))
    `${ph} = :new`
  })
  {
    TransactWriteCommand.key: fenceKey(tag),
    tableName,
    updateExpression: `SET ${setClauses->Array.join(", ")}`,
    expressionAttributeNames: names,
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
  ~consumedTypes: array<string>,
  ~after: option<string>,
): TransactWriteCommand.conditionCheck => {
  let names = Dict.make()
  switch after {
  | None =>
    let conditionExpression =
      consumedTypes
      ->Array.mapWithIndex((t, i) => {
        let ph = `#c${i->Int.toString}`
        names->Dict.set(ph, fenceTypeAttr(t))
        `attribute_not_exists(${ph})`
      })
      ->Array.join(" AND ")
    {
      TransactWriteCommand.key: fenceKey(tag),
      tableName,
      conditionExpression,
      expressionAttributeNames: names,
    }
  | Some(pos) =>
    let conditionExpression =
      consumedTypes
      ->Array.mapWithIndex((t, i) => {
        let ph = `#c${i->Int.toString}`
        names->Dict.set(ph, fenceTypeAttr(t))
        `(attribute_not_exists(${ph}) OR ${ph} <= :after)`
      })
      ->Array.join(" AND ")
    {
      TransactWriteCommand.key: fenceKey(tag),
      tableName,
      conditionExpression,
      expressionAttributeNames: names,
      expressionAttributeValues: Dict.fromArray([(":after", pos->JSON.Encode.string)]),
    }
  }
}

// The create guard is now FOLDED INTO THE FENCE (see `buildConditionalFenceUpdate`).
// At `after=None` the partition-tag fence is a conditional Update gated on
// `attribute_not_exists(pos#<producedType>)`, which serializes concurrent
// first-writers of the same `(producedType, partition)` without a separate sentinel
// row. The old per-(eventType, partition) `create#…` rows are retired — per-type
// `pos#` attributes are type-scoped, so they don't false-conflict a subset-type
// slice the way a scalar `lastPosition` did (analysis Issues 2 & 4).

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
    | DynamoDb_Error.StaleState(_msg) => Effect.succeed(Error(ReventlessInfra.DcbEventLog.Conflict))
    | Transient(msg) | Permanent(msg) =>
      Effect.succeed(Error(ReventlessInfra.DcbEventLog.StorageFailure(`${errorPrefix}: ${msg}`)))
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
      ReventlessInfra.DcbEventLog.StorageFailure(
        `DCB append: TransactWriteItems limit exceeded (${totalItems->Int.toString} > ${transactWriteItemsLimit->Int.toString}); reduce events or distinct tag values per command`,
      ),
    )
  } else {
    let basePosition = generatePosition()
    let carriedMap = carriedTypesByTag(events)
    let putItems = buildEventPuts(table, events, basePosition, ~partitionTag?)
    let updateItems =
      eventTags->Array.filterMap(tag => {
        let producedTypes = carriedMap->Dict.get(`${tag.key}:${tag.value}`)->Option.getOr([])
        producedTypes->Array.length == 0
          ? None
          : Some({
              TransactWriteCommand.update: buildUnconditionalFenceUpdate(
                table.name,
                tag,
                ~producedTypes,
                ~newPosition=basePosition,
              ),
            })
      })
    let input: TransactWriteCommand.input = {
      transactItems: Array.concat(putItems, updateItems),
    }
    await runTransactWrite(input, basePosition, ~errorPrefix="DCB append failed")
  }
}

// A Composite partition fences on the WHOLE composite value, not on each member.
// The synthetic fence tag is keyed on `getCompositePartitionKeyValue` — the same
// value `derivePartitionKey` uses for the base-table `id` — so it is exactly as
// selective as the entity's storage partition (and the `tag_composite` read
// scope). Fencing per-member (the historical behaviour) gave every low-cardinality
// member (e.g. `environment`, `platformName`) its own fence, which a deploy-time
// fan-out sharing those prefixes turns into a hot partition → `TransactionConflict`
// → `retries exhausted`; it also over-fenced (two DISTINCT composite entities
// sharing a member value serialized needlessly). Plan:
// docs/plans/Backlog/dcb-hot-tag-fence-contention.md § "Root-cause correction".
let compositeFenceTagKey = "__dcb_composite__"

let makeCompositeFenceTag = (
  tags: array<Reventless.DcbTag.tag>,
  spec: Reventless.DcbTag.compositePartitionSpec,
): Reventless.DcbTag.tag => {
  key: compositeFenceTagKey,
  value: Reventless.DcbTag.getCompositePartitionKeyValue(tags, spec),
}

// The partition tag(s) of a written event — the ONLY fences an append may BUMP.
// A tag's fence must track exactly the partition-scoped events a single-tag read
// of that tag observes (events are stored under `id="<partitionKey>:<value>"`),
// so only the partition tag may advance it. Mirrors `derivePartitionKey`.
//
// A Composite partition collapses to a single synthetic composite fence tag (see
// `makeCompositeFenceTag`) — one fence per composite entity, not one per member.
let eventPartitionTags = (
  event: ReventlessCore.DcbEventLog_Adapter.rawStoredEvent,
  ~partitionTag: option<Reventless.DcbTag.derivedPartitionTag>,
): array<Reventless.DcbTag.tag> =>
  switch partitionTag {
  | Some(Composite(spec)) => [makeCompositeFenceTag(event.tags, spec)]
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

// tagKey ("key:value") -> distinct event types among `events` PARTITIONED by the
// tag. A partition-scoped fence advances only for events whose partition tag is this
// one (Issue 1), so this is the produced-type set for partition-tag bumps/updates.
let partitionTypesByTag = (
  events: array<ReventlessCore.DcbEventLog_Adapter.rawStoredEvent>,
  ~partitionTag: option<Reventless.DcbTag.derivedPartitionTag>,
): Dict.t<array<string>> => {
  let d = Dict.make()
  events->Array.forEach(e =>
    eventPartitionTags(e, ~partitionTag)->Array.forEach((t: Reventless.DcbTag.tag) => {
      let k = `${t.key}:${t.value}`
      let cur = d->Dict.get(k)->Option.getOr([])
      if !(cur->Array.includes(e.eventType)) {
        d->Dict.set(k, cur->Array.concat([e.eventType]))
      }
    })
  )
  d
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
  ~crossPartitionTagKeys: array<string>=[],
): array<TransactWriteCommand.transactWriteItem> => {
  // For a Composite partition, fold the multi-tag composite read clause into a
  // single synthetic composite fence tag (`makeCompositeFenceTag`) so the rest of
  // this function fences it exactly like a Simple partition — one fence per
  // composite entity — instead of once per member (the hot-fence source). Only the
  // FENCE view of the query is rewritten here; the read path (`readStream`) keeps
  // the original member tags and its `tag_composite` GSI lookup. Gated on
  // `Composite`: Simple-partition composite-read slices (e.g. RecordProductDemand's
  // `{productId, orderId}` pair, where `productId` is a real independent partition)
  // are left untouched. `@crossPartition` carriers are unaffected — they are
  // handled by `crossPartitionEventTags` below, not by this composite clause.
  let cond = switch partitionTag {
  | Some(Composite(spec)) => {
      ...cond,
      query: cond.query->Array.map(qi =>
        switch qi.tags {
        | Some(clauseTags) if clauseTags->Array.length > 1 => {
            ...qi,
            tags: [makeCompositeFenceTag(clauseTags, spec)],
          }
        | _ => qi
        }
      ),
    }
  | _ => cond
  }

  // The partitions this append writes into — the only fences it may BUMP
  // (partition-scoped tags only; cross-partition tags below override this).
  let partitionTags = collectEventPartitionTags(events, ~partitionTag)
  let partitionKeySet = Set.make()
  partitionTags->Array.forEach(t => partitionKeySet->Set.add(`${t.key}:${t.value}`))
  let isPartition = (t: Reventless.DcbTag.tag) => partitionKeySet->Set.has(`${t.key}:${t.value}`)

  // Cross-partition tags this append must fence regardless of which partition it
  // writes into. A `@crossPartition` tag is read across ALL partitions (per-tag
  // GSI), so OCC requires EVERY carrier — primary or secondary — to bump its
  // fence; else a concurrent secondary-tag writer goes undetected. This reverts
  // Issue 1's narrowing, but only for tags declared cross-partition (analysis
  // Issue 13). Partition-scoped tags keep the narrow rule.
  let isCrossPartition = (t: Reventless.DcbTag.tag) => crossPartitionTagKeys->Array.includes(t.key)
  let crossPartitionEventTags = collectEventTags(events)->Array.filter(isCrossPartition)

  // Per-type position maps: which event types this append advances for each tag.
  // Partition-scoped tags advance only for events partitioned by them (Issue 1);
  // composite query tags and cross-partition tags advance for every carrier.
  let carriedMap = carriedTypesByTag(events)
  let partitionMap = partitionTypesByTag(events, ~partitionTag)
  let producedTypesFor = (t: Reventless.DcbTag.tag) => {
    let k = `${t.key}:${t.value}`
    (isPartition(t) && !isCrossPartition(t) ? partitionMap : carriedMap)
    ->Dict.get(k)
    ->Option.getOr([])
  }

  // Consumed event types per tag value, from the query clauses — the OCC check
  // scope. A clause with no `eventTypes` contributes nothing (vacuous — Issue 14).
  let consumedMap = Dict.make()
  cond.query->Array.forEach(qi =>
    switch (qi.tags, qi.eventTypes) {
    | (Some(tags), Some(ets)) =>
      tags->Array.forEach(t => {
        let k = `${t.key}:${t.value}`
        let cur = consumedMap->Dict.get(k)->Option.getOr([])
        consumedMap->Dict.set(k, dedupStrings(Array.concat(cur, ets)))
      })
    | _ => ()
    }
  )
  let consumedTypesFor = (t: Reventless.DcbTag.tag) =>
    consumedMap->Dict.get(`${t.key}:${t.value}`)->Option.getOr([])

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

  cond.query->Array.forEach(qi =>
    switch qi.tags {
    // Single-tag clause. A `@crossPartition` tag is a cross-partition read, so
    // its fence is BUMPED (conditional Update) by every carrier. A partition-scoped
    // tag keeps the narrow rule: BUMP only when this append writes into that
    // partition (or it backs a composite read), else read-only ConditionCheck. At
    // after=None the partition tag becomes a conditional Update too — the FOLDED
    // CREATE GUARD (`attribute_not_exists(pos#<producedType>)`) serializing
    // first-writers; the per-type attribute keeps it from false-conflicting a
    // subset-type slice. Non-partition single tags at after=None do nothing.
    | Some([tag]) =>
      if isCrossPartition(tag) {
        pushUpdate(tag)
      } else {
        switch cond.after {
        | Some(_) =>
          if isPartition(tag) || isCompositeQueryTag(tag) {
            pushUpdate(tag)
          } else {
            pushCheck(tag)
          }
        | None =>
          if isPartition(tag) {
            pushUpdate(tag)
          }
        }
      }
    // Multi-tag clause = composite (GSI) read — keep check+bump on every tag at
    // after=Some; at after=None the composite tags fall through to bumps below.
    | Some(tags) if tags->Array.length > 1 =>
      switch cond.after {
      | Some(_) => tags->Array.forEach(pushUpdate)
      | None => ()
      }
    | _ => ()
    }
  )

  // Folded create guard coverage: ensure EVERY event partition tag is a conditional
  // Update at after=None, even one that never appeared as its own single-tag query
  // clause (matches the old per-(eventType, partition) create guard's reach).
  // `pushUpdate` dedups, so a partition tag already routed above is untouched.
  switch cond.after {
  | None => partitionTags->Array.forEach(pushUpdate)
  | Some(_) => ()
  }

  // Unconditional bumps. Advance fences for the partitions this append writes into
  // (so future partition-scoped readers detect it) plus composite query tags (so
  // composite readers detect it) plus every cross-partition tag this event carries
  // (primary OR secondary — a cross-partition reader of that tag must detect this
  // write even when this command does not read by it), minus anything a conditional
  // Update already bumps. Partition-scoped secondary event tags are still NEVER
  // bumped here — doing so was the source of the cross-partition false conflicts.
  let bumpSeen = Set.make()
  conditionalUpdateTags->Array.forEach(t => bumpSeen->Set.add(`${t.key}:${t.value}`))
  let bumpTags = []
  let candidateBumps = switch cond.after {
  | Some(_) => Array.concat(partitionTags, crossPartitionEventTags)
  | None => Array.concat(partitionTags, Array.concat(compositeQueryTags, crossPartitionEventTags))
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
    conditionalUpdateTags->Array.filterMap(tag => {
      let producedTypes = producedTypesFor(tag)
      // A conditional Update must advance ≥1 produced type; partition / composite /
      // cross-partition carriers always have one. If none (a misconfigured clause),
      // skip rather than emit an empty `SET`.
      producedTypes->Array.length == 0
        ? None
        : Some({
            TransactWriteCommand.update: buildConditionalFenceUpdate(
              table.name,
              tag,
              ~consumedTypes=consumedTypesFor(tag),
              ~producedTypes,
              ~newPosition=basePosition,
              ~after=cond.after,
            ),
          })
    })
  let checkItems =
    conditionCheckTags->Array.filterMap(tag => {
      let consumedTypes = consumedTypesFor(tag)
      // A vacuous clause (no consumed type carries the tag) matches nothing — skip.
      consumedTypes->Array.length == 0
        ? None
        : Some({
            TransactWriteCommand.conditionCheck: buildFenceConditionCheck(
              table.name,
              tag,
              ~consumedTypes,
              ~after=cond.after,
            ),
          })
    })
  let bumpItems =
    bumpTags->Array.filterMap(tag => {
      let producedTypes = producedTypesFor(tag)
      producedTypes->Array.length == 0
        ? None
        : Some({
            TransactWriteCommand.update: buildUnconditionalFenceUpdate(
              table.name,
              tag,
              ~producedTypes,
              ~newPosition=basePosition,
            ),
          })
    })

  Array.concat(putItems, Array.concat(updateItems, Array.concat(checkItems, bumpItems)))
}

let appendConditional = async (
  table: resolvedTable,
  events: array<ReventlessCore.DcbEventLog_Adapter.rawStoredEvent>,
  cond: Reventless.DcbTag.appendCondition,
  ~partitionTag=?,
  ~crossPartitionTagKeys: array<string>=[],
) => {
  let queryTags = collectQueryTags(cond.query)

  if queryTags->Array.length == 0 {
    Error(
      ReventlessInfra.DcbEventLog.StorageFailure(
        "DCB append: tagless conditions are not supported on DynamoDB — every queryItem must have at least one tag",
      ),
    )
  } else {
    let basePosition = generatePosition()
    let transactItems = buildConditionalTransactItems(table, events, cond, basePosition, ~partitionTag?, ~crossPartitionTagKeys)
    let totalItems = transactItems->Array.length
    if totalItems > transactWriteItemsLimit {
      Error(
        ReventlessInfra.DcbEventLog.StorageFailure(
          `DCB append: TransactWriteItems limit exceeded (${totalItems->Int.toString} > ${transactWriteItemsLimit->Int.toString}); reduce events or distinct tag values per command`,
        ),
      )
    } else {
      let input: TransactWriteCommand.input = {transactItems: transactItems}
      await runTransactWrite(input, basePosition, ~errorPrefix="DCB append failed")
    }
  }
}

let append = (table: resolvedTable, ~partitionTag=?, ~crossPartitionTagKeys: array<string>=[]) =>
  async (
    events: array<ReventlessCore.DcbEventLog_Adapter.rawStoredEvent>,
    ~condition=?,
  ) => {
    switch condition {
    | None => await appendUnconditional(table, events, ~partitionTag?)
    | Some(cond) => await appendConditional(table, events, cond, ~partitionTag?, ~crossPartitionTagKeys)
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
  let filter = buildScanFilter(~eventTypes?)

  let baseParams: ScanCommand.input = {
    tableName: table.name,
    filterExpression: ?filter.filterExpression,
    expressionAttributeValues: ?filter.expressionAttributeValues,
    expressionAttributeNames: ?filter.expressionAttributeNames,
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
  ~strongConsistency: bool=false,
  ~crossPartitionTagKeys: array<string>=[],
) => {
  switch queryItem.tags {
  // Single tag: a `@crossPartition` key reads every partition via the per-tag
  // GSI (eventually consistent — fence catches staleness); otherwise a direct
  // base-table partition lookup. Base-table reads can opt into strong
  // consistency; the slice callback defaults to eventual and escalates on retry.
  // GSI-backed branches (cross-partition, composite, scan) cannot opt in —
  // fundamental DynamoDB constraint — so they stay eventually consistent.
  | Some([tag]) if crossPartitionTagKeys->Array.includes(tag.key) =>
    queryBySingleTagCrossPartitionStream(table, tag, ~after?)
  | Some([tag]) =>
    queryByPartitionKeyStream(
      table,
      `${tag.key}:${tag.value}`,
      ~after?,
      ~strongConsistency,
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

let readStream = (table: resolvedTable, ~crossPartitionTagKeys: array<string>=[]) =>
  (~query: Reventless.DcbTag.query, ~after=?, ~strongConsistency=false) => {
    let streams =
      query->Array.map(qi =>
        executeQueryItemStream(table, qi, ~after?, ~strongConsistency, ~crossPartitionTagKeys)
      )
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
