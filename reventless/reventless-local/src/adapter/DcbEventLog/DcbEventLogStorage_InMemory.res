// In-memory DCB event log storage.
// Mirrors the mock storage in packages/reventless/tests/dcb/DcbFixtures.res

open ReventlessCore

let posToInt = (pos: string) => pos->Int.fromString->Option.getOr(0)

let matchesQuery = (event: DcbEventLog_Adapter.rawSequencedEvent, query: Reventless.DcbTag.query) =>
  if query->Array.length == 0 {
    true
  } else {
    query->Array.some(queryItem => {
      let typeMatch = switch queryItem.eventTypes {
      | Some(types) => types->Array.includes(event.eventType)
      | None => true
      }
      let tagMatch = switch queryItem.tags {
      | Some(tags) =>
        tags->Array.every(tag =>
          event.tags->Array.some(et => et.key == tag.key && et.value == tag.value)
        )
      | None => true
      }
      typeMatch && tagMatch
    })
  }

// Composite key for the per-(key,value) tag posting list. NUL can't appear in a
// tag key or value, so it's an unambiguous separator.
let tagPostingKey = (key: string, value: string) => key ++ "\x00" ++ value

// Intersect two ascending, duplicate-free index arrays (two-pointer merge).
let intersectSorted = (a: array<int>, b: array<int>): array<int> => {
  let out = []
  let i = ref(0)
  let j = ref(0)
  while i.contents < a->Array.length && j.contents < b->Array.length {
    let av = a->Array.getUnsafe(i.contents)
    let bv = b->Array.getUnsafe(j.contents)
    if av == bv {
      out->Array.push(av)
      i := i.contents + 1
      j := j.contents + 1
    } else if av < bv {
      i := i.contents + 1
    } else {
      j := j.contents + 1
    }
  }
  out
}

let makeStorage = (~name as _name, ~indexes as _, ~partitionTag as _, ~opts as _) => {
  let events: ref<array<DcbEventLog_Adapter.rawSequencedEvent>> = ref([])
  let position = ref(0)
  // Posting lists: tag "key\0value" / eventType → ascending array indices into
  // `events`. Events are only ever appended (never removed) in position order, so
  // every list stays sorted and duplicate-free by construction. They turn the
  // per-read / per-conditional-append full scan (O(n) → O(n²) over a session)
  // into a lookup + intersection over the (usually tiny) candidate set.
  let byTag: Dict.t<array<int>> = Dict.make()
  let byType: Dict.t<array<int>> = Dict.make()
  let pushInto = (dict: Dict.t<array<int>>, key: string, idx: int) =>
    switch dict->Dict.get(key) {
    | Some(list) => list->Array.push(idx)
    | None => dict->Dict.set(key, [idx])
    }
  let indexEvent = (idx: int, ev: DcbEventLog_Adapter.rawSequencedEvent) => {
    pushInto(byType, ev.eventType, idx)
    ev.tags->Array.forEach(t => pushInto(byTag, tagPostingKey(t.key, t.value), idx))
  }

  // Ascending, duplicate-free superset of the indices that could satisfy the
  // query (an OR of clauses). Narrowing only — the authoritative `matchesQuery`
  // predicate is still applied to each candidate, so the result is identical to
  // the old linear scan even if this over-includes. Callers guarantee query≠[].
  let candidateIndices = (query: Reventless.DcbTag.query): array<int> => {
    let acc: Dict.t<int> = Dict.make()
    let addAll = (arr: array<int>) => arr->Array.forEach(i => acc->Dict.set(Int.toString(i), i))
    query->Array.forEach(clause => {
      switch clause.tags {
      | Some(tags) if tags->Array.length > 0 =>
        // Events carrying ALL of the clause's tags = intersection of the tags'
        // posting lists; a missing tag ⇒ empty ⇒ this clause adds nothing.
        let lists = tags->Array.map(t =>
          byTag->Dict.get(tagPostingKey(t.key, t.value))->Option.getOr([])
        )
        if lists->Array.some(l => l->Array.length == 0) {
          ()
        } else {
          let sorted = lists->Array.toSorted((a, b) => Int.toFloat(a->Array.length - b->Array.length))
          let acc0 = sorted->Array.getUnsafe(0)
          let folded =
            sorted->Array.slice(~start=1, ~end=sorted->Array.length)->Array.reduce(acc0, intersectSorted)
          addAll(folded)
        }
      | _ =>
        // No tag constraint: narrow by event type when present (union of the
        // types' posting lists — disjoint since an event has one type), else the
        // clause is unconstrained and matches everything.
        switch clause.eventTypes {
        | Some(types) => types->Array.forEach(t => addAll(byType->Dict.get(t)->Option.getOr([])))
        | None => events.contents->Array.forEachWithIndex((_, i) => acc->Dict.set(Int.toString(i), i))
        }
      }
    })
    acc->Dict.valuesToArray->Array.toSorted((a, b) => Int.toFloat(a - b))
  }

  let matchingEvents = (~query, ~after): array<DcbEventLog_Adapter.rawSequencedEvent> => {
    let pass = (ev: DcbEventLog_Adapter.rawSequencedEvent) => {
      let afterMatch = switch after {
      | Some(afterPos) => ev.position->posToInt > afterPos->posToInt
      | None => true
      }
      afterMatch && matchesQuery(ev, query)
    }
    if query->Array.length == 0 {
      events.contents->Array.filter(pass)
    } else {
      candidateIndices(query)->Array.filterMap(i => {
        let ev = events.contents->Array.getUnsafe(i)
        pass(ev) ? Some(ev) : None
      })
    }
  }

  let read = async (~query, ~after=?) => {
    let filtered = matchingEvents(~query, ~after)
    let headPosition =
      events.contents
      ->Array.get(events.contents->Array.length - 1)
      ->Option.map(e => e.position)
    {
      DcbEventLog_Adapter.events: filtered,
      ?headPosition,
    }
  }

  let append = async (newEvents, ~condition=?) => {
    let conflictDetected = switch condition {
    | Some(cond: Reventless.DcbTag.appendCondition) =>
      matchingEvents(~query=cond.query, ~after=cond.after)->Array.length > 0
    | None => false
    }
    if conflictDetected {
      Error("conflict: condition check failed")
    } else {
      let base = events.contents->Array.length
      let storedEvents =
        newEvents->Array.mapWithIndex((event: DcbEventLog_Adapter.rawStoredEvent, j) => {
          position := position.contents + 1
          let pos = position.contents->Int.toString
          let stored: DcbEventLog_Adapter.rawSequencedEvent = {
            position: pos,
            eventType: event.eventType,
            data: event.data,
            tags: event.tags,
            meta: event.meta,
            recordedAt: Message.nowAsISOString(),
          }
          indexEvent(base + j, stored)
          stored
        })
      events := events.contents->Array.concat(storedEvents)
      Ok(position.contents->Int.toString)
    }
  }

  // ~strongConsistency is a DynamoDB read-replica concept; the in-memory backend
  // is always consistent, so it is accepted (interface parity) and ignored.
  let readStream = (~query, ~after=?, ~strongConsistency as _=?) =>
    Effect.promise(() => read(~query, ~after?))
    ->Effect.map(result => result.events)
    ->Stream.fromEffect
    ->Stream.flatMap(arr => Stream.fromIterable(arr))

  (
    _name,
    read,
    {
      DcbEventLog_Adapter.resources: [],
      operations: Pulumi.Output.make({DcbEventLog_Adapter.read, append, readStream}),
    },
  )
}

// Local backends evaluate the DCB condition literally against the event list
// (true DCB semantics), so a single-tag clause already matches every carrier of
// the tag regardless of partition — cross-partition reads work without special
// routing. The flag is accepted for interface parity and ignored.
let make: DcbEventLog_Adapter.storageMaker = (~name, ~indexes, ~partitionTag, ~crossPartitionTagKeys as _=?, ~opts) => {
  let (_, _, storage) = makeStorage(~name, ~indexes, ~partitionTag, ~opts)
  storage
}

module Make = (Bus: LocalBus.T) => {
  let make: DcbEventLog_Adapter.storageMaker = (~name, ~indexes, ~partitionTag, ~crossPartitionTagKeys as _=?, ~opts) => {
    switch BackendState.getDb() {
    | Some(db) =>
      let (storageName, read, storage) = DcbEventLogStorage_Sqlite.makeStorage(
        ~db,
        ~bus=(_, _) => (),
        ~publishToTopic=(~topicName as _, ~json as _) => (),
        ~name,
        ~indexes,
        ~partitionTag,
        ~opts,
      )
      Bus.registerDcbEventLogRead(storageName, read)
      storage
    | None =>
      let (storageName, read, storage) = makeStorage(~name, ~indexes, ~partitionTag, ~opts)
      Bus.registerDcbEventLogRead(storageName, read)
      storage
    }
  }
}
