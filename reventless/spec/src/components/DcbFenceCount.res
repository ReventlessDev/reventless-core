/**
A cross-partition read goes through an eventually consistent index, which can
miss an event. Its fence counts the events of each type that carry its tag value,
so a reader compares what it read with what was counted and knows when it missed
one. A fence's count is trusted only once `counted` says it includes the events
written before counting began.
*/
/** One cross-partition fence as a strongly consistent read found it. */
type fence = {
  tag: DcbTag.tag,
  counted: bool,
  /** Events counted, by event type. A type missing here counted none. */
  counts: dict<int>,
}

/** A single-tag clause of a cross-partition key, with the types it reads. */
type clause = {
  tag: DcbTag.tag,
  eventTypes: array<string>,
}

/** A type a reader read fewer events of than its fence counted. */
type shortfall = {
  tag: DcbTag.tag,
  eventType: string,
  read: int,
  counted: int,
}

let tagId = (tag: DcbTag.tag) => `${tag.key}:${tag.value}`

/** The key a read count is kept under: the tag value and the event type. */
let seenKey = (tag: DcbTag.tag, eventType) => `${tagId(tag)}|${eventType}`

/** The clauses of `query` that read across partitions and name their types: by a
    key the boundary reads that way, or as a pair's clause. */
let clauses = (query: DcbTag.query, ~crossPartitionTagKeys: array<string>): array<clause> =>
  query->Array.filterMap(qi =>
    switch (qi.tags, qi.eventTypes) {
    | (Some([tag]), Some(eventTypes))
      if (qi.crossPartition == Some(true) || crossPartitionTagKeys->Array.includes(tag.key)) &&
        eventTypes->Array.length > 0 =>
      Some({tag, eventTypes})
    | _ => None
    }
  )

/** Adds one read event to `seen` for every clause it matches. */
let countRead = (
  seen: dict<int>,
  clauses: array<clause>,
  ~eventType: string,
  ~tags: array<DcbTag.tag>,
) =>
  clauses->Array.forEach(c =>
    if (
      c.eventTypes->Array.includes(eventType) &&
        tags->Array.some(t => t.key == c.tag.key && t.value == c.tag.value)
    ) {
      let k = seenKey(c.tag, eventType)
      seen->Dict.set(k, seen->Dict.get(k)->Option.getOr(0) + 1)
    }
  )

/** Every type of a counted fence the reader read fewer events of than were counted. */
let shortfalls = (fences: array<fence>, clauses: array<clause>, seen: dict<int>): array<
  shortfall,
> =>
  clauses->Array.flatMap(c =>
    switch fences->Array.find(f => tagId(f.tag) == tagId(c.tag)) {
    | Some(f) if f.counted =>
      c.eventTypes->Array.filterMap(eventType => {
        let counted = f.counts->Dict.get(eventType)->Option.getOr(0)
        let read = seen->Dict.get(seenKey(c.tag, eventType))->Option.getOr(0)
        read < counted ? Some({tag: c.tag, eventType, read, counted}) : None
      })
    | _ => []
    }
  )

/** What the reader read of each type of each counted fence, for the append to check. */
let readCounts = (fences: array<fence>, clauses: array<clause>, seen: dict<int>): array<
  DcbTag.fenceCount,
> =>
  clauses->Array.flatMap(c =>
    switch fences->Array.find(f => tagId(f.tag) == tagId(c.tag)) {
    | Some(f) if f.counted =>
      c.eventTypes->Array.map((eventType): DcbTag.fenceCount => {
        tag: c.tag,
        eventType,
        count: seen->Dict.get(seenKey(c.tag, eventType))->Option.getOr(0),
      })
    | _ => []
    }
  )
