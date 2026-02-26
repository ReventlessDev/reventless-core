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

let make: DcbEventLog_Adapter.storageMaker = (~name as _, ~indexes as _, ~opts as _) => {
  let events: ref<array<DcbEventLog_Adapter.rawSequencedEvent>> = ref([])
  let position = ref(0)

  let read = async (~query, ~after=?) => {
    let filtered = events.contents->Array.filter(event => {
      let afterMatch = switch after {
      | Some(afterPos) => event.position->posToInt > afterPos->posToInt
      | None => true
      }
      afterMatch && matchesQuery(event, query)
    })
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
      events.contents->Array.some(event => {
        let afterMatch = switch cond.after {
        | Some(pos) => event.position->posToInt > pos->posToInt
        | None => true
        }
        afterMatch && matchesQuery(event, cond.query)
      })
    | None => false
    }
    if conflictDetected {
      Error("conflict: condition check failed")
    } else {
      let storedEvents =
        newEvents->Array.map((event: DcbEventLog_Adapter.rawStoredEvent) => {
          position := position.contents + 1
          let pos = position.contents->Int.toString
          {
            DcbEventLog_Adapter.position: pos,
            eventType: event.eventType,
            data: event.data,
            tags: event.tags,
          }
        })
      events := events.contents->Array.concat(storedEvents)
      Ok(position.contents->Int.toString)
    }
  }

  {
    resources: [],
    operations: Pulumi.Output.make({DcbEventLog_Adapter.read, append}),
  }
}
