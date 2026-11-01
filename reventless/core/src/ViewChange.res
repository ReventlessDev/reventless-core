// What a projection changed in a view: one row created, changed or removed, and
// the events that led to it.
//
// Each change becomes an info log line `view changed` carrying the view, the
// row's key, the kind of change, the names of the fields that changed, and the
// events' message ids and entities, never the values: a log group cannot be swept
// for one person. A listener registered here (a platform that serves a watching
// tool, say) receives the change with the row before and after, as JSON, and
// redacts them itself if it sends them anywhere.

type kind = Projection.changeKind

/** One row change, as the log line and the listeners see it. */
type t = {
  view: string,
  key: string,
  subId?: string,
  kind: kind,
  /** The top-level fields whose values differ; every field of the row where
      only one side is known. */
  fields: array<string>,
  before?: JSON.t,
  after?: JSON.t,
  sources: array<Projection.changeSource>,
  /** The flow the events share, when they all share one. */
  correlationId?: string,
}

type listener = t => unit

type registered = {id: int, listener: listener}

let listeners: ref<array<registered>> = ref([])
let nextId = ref(0)

/** Adds a listener and returns the function that removes it. */
let register = (listener: listener): (unit => unit) => {
  nextId := nextId.contents + 1
  let id = nextId.contents
  listeners := listeners.contents->Array.concat([{id, listener}])
  () => listeners := listeners.contents->Array.filter(l => l.id != id)
}

/** Removes every listener. */
let clear = () => listeners := []

let kindLabel = (kind: kind) =>
  switch kind {
  | Created => "created"
  | Changed => "changed"
  | Removed => "removed"
  }

/** The names of the top-level fields that differ between the two sides. */
let changedFields = (~before: option<JSON.t>, ~after: option<JSON.t>): array<string> => {
  let objectOf = side => side->Option.flatMap(JSON.Decode.object)
  switch (objectOf(before), objectOf(after)) {
  | (Some(b), Some(a)) =>
    let names = a->Dict.keysToArray
    b
    ->Dict.keysToArray
    ->Array.forEach(name =>
      if !(names->Array.includes(name)) {
        names->Array.push(name)
      }
    )
    names->Array.filter(name => b->Dict.get(name) != a->Dict.get(name))
  | (None, Some(one)) | (Some(one), None) => one->Dict.keysToArray
  | (None, None) => []
  }
}

let sharedCorrelationId = (sources: array<Projection.changeSource>): option<string> =>
  switch sources->Array.map(s => s.correlationId) {
  | [] => None
  | ids =>
    let first = ids->Array.getUnsafe(0)
    ids->Array.every(id => id == first) ? first : None
  }

let sourceToJson = (s: Projection.changeSource): JSON.t =>
  [("msgId", JSON.Encode.string(s.msgId))]
  ->Array.concat(s.correlationId->Option.mapOr([], c => [("correlationId", JSON.Encode.string(c))]))
  ->Array.concat(s.entityId->Option.mapOr([], e => [("entityId", JSON.Encode.string(e))]))
  ->Array.concat(s.entityType->Option.mapOr([], e => [("entityType", JSON.Encode.string(e))]))
  ->Dict.fromArray
  ->JSON.Encode.object

/** The fields both the log line's detail and a feed line carry: everything but
    the values. */
let summaryFields = (c: t): array<(string, JSON.t)> =>
  [("view", JSON.Encode.string(c.view)), ("key", JSON.Encode.string(c.key))]
  ->Array.concat(c.subId->Option.mapOr([], s => [("subId", JSON.Encode.string(s))]))
  ->Array.concat([
    ("change", JSON.Encode.string(kindLabel(c.kind))),
    ("fields", c.fields->Array.map(JSON.Encode.string)->JSON.Encode.array),
    ("sources", c.sources->Array.map(sourceToJson)->JSON.Encode.array),
  ])

let logLine = (~comp: string, c: t) =>
  Logger.emit(
    ~level=Info,
    ~comp,
    ~annotations=c.correlationId->Option.mapOr(Dict.make(), id =>
      Dict.fromArray([("correlationId", id)])
    ),
    ~detail=c->summaryFields->Dict.fromArray->JSON.Encode.object,
    "view changed",
  )

/**
The `~onChange` a projection's caller passes to `Projection.handleAction`:
logs each change and hands it to the listeners. `stateToJson` encodes a row the
way the view stores it; a row it cannot encode counts as unknown. Nothing is
encoded when the line is below its level and nobody listens.
*/
let reporter = (~comp: string, ~view: string, ~stateToJson: 'state => JSON.t): (
  Projection.rowChange<'state> => unit
) =>
  change => {
    let logs = Logger.shouldLog(Info, ~comp, ())
    let listening = listeners.contents != []
    if logs || listening {
      let toJson = state =>
        switch stateToJson(state) {
        | json => Some(json)
        | exception _ => None
        }
      let before = change.before->Option.flatMap(toJson)
      let after = change.after->Option.flatMap(toJson)
      let fields = changedFields(~before, ~after)
      // An update that wrote the row as it was changed nothing a reader can see.
      let unchanged = switch (change.kind, before, after) {
      | (Changed, Some(_), Some(_)) => fields == []
      | _ => false
      }
      if !unchanged {
        let c = {
          view,
          key: change.key,
          subId: ?change.subId,
          kind: change.kind,
          fields,
          ?before,
          ?after,
          sources: change.sources,
          correlationId: ?sharedCorrelationId(change.sources),
        }
        if logs {
          logLine(~comp, c)
        }
        listeners.contents->Array.forEach(({listener}) =>
          try listener(c) catch {
          | exn =>
            Console.error(
              `a view-change listener failed and is skipped for that change: ${exn
                ->JsExn.fromException
                ->Option.flatMap(JsExn.message)
                ->Option.getOr("unknown")}`,
            )
          }
        )
      }
    }
  }

/** The source of a change from an event's meta and the entity it is about. */
let sourceOf = (
  ~meta: Reventless.Message.meta,
  ~entityId: option<string>=?,
  ~entityType: option<string>=?,
  (),
): Projection.changeSource => {
  msgId: meta.msgId,
  correlationId: meta.correlationId,
  ?entityId,
  ?entityType,
}

/** The entity a stored event's envelope is about: its first tag (value and key)
    when it has tags, a DCB event; otherwise its `id`, an aggregate's. */
let entityOfEnvelope = (envelope: dict<JSON.t>): (option<string>, option<string>) => {
  let firstTag =
    envelope
    ->Dict.get("tags")
    ->Option.flatMap(JSON.Decode.array)
    ->Option.flatMap(tags => tags->Array.get(0))
    ->Option.flatMap(JSON.Decode.object)
  let string = (d, k) => d->Dict.get(k)->Option.flatMap(JSON.Decode.string)
  switch firstTag {
  | Some(tag) => (string(tag, "value"), string(tag, "key"))
  | None => (string(envelope, "id"), None)
  }
}
