// Local (yoga) resolvers for the event-history queries whose SDL is emitted by
// `Plugin_EventQuerySchema` — the historical read counterpart of the Source A
// raw-event subscription.
//
// Two flavours of event log land in the same `eventLogEntries` array and are
// read differently, exactly as the MCP event-history handler in Platform.res
// forks them:
//
//   aggregate log → Bus.getEventLogReplay(busKey)   — replay by entity id
//   DCB log       → Bus.getDcbEventLogRead(busKey)  — read(~query) by tag
//
// The difference that matters to a caller: an aggregate log is only readable
// *per entity* (replay takes an id), so a filter-less plugin-wide query over
// one returns nothing and says so. A DCB log answers both.
//
// Unlike the MCP handler, this keeps `meta` and `recordedAt` — who caused each
// change and when is the point of reading a history at all.

open ReventlessCore

// Positions are numeric strings. Comparing them lexically silently breaks the
// moment a log crosses a digit boundary ("10" > "9" is false as strings), which
// makes cursor pages skip or duplicate events. One implementation, used for
// both the sort and the cursor bound.
let comparePosition = (a: string, b: string): float =>
  switch (Int.fromString(a), Int.fromString(b)) {
  | (Some(ai), Some(bi)) => (ai - bi)->Int.toFloat
  | _ =>
    if a < b {
      -1.
    } else if a > b {
      1.
    } else {
      0.
    }
  }

let positionGt = (a, b) => comparePosition(a, b) > 0.
let positionLt = (a, b) => comparePosition(a, b) < 0.

// ── The normalised record every branch produces ──────────────────────────────
// Mirrors the `{N}EventRecord` SDL type field for field.

type record = {
  position: string,
  eventType: string,
  payload: JSON.t,
  tags: array<Reventless.DcbTag.tag>,
  meta: JSON.t,
  recordedAt: string,
}

let str = JSON.Encode.string
let optStr = o => o->Option.mapOr(JSON.Encode.null, str)

// Only the audit-relevant subset of `Message.meta` crosses to the client —
// `ip`, `traceparent`, `schemaVersion` and the `headers` context bag are
// deliberately dropped here as well as in the SDL, so a future SDL widening
// can't quietly start leaking them.
let metaJson = (m: Reventless.Message.meta): JSON.t =>
  Dict.fromArray([
    ("service", str(m.service)),
    ("time", str(m.time)),
    ("user", optStr(m.user)),
    ("msgId", str(m.msgId)),
    ("correlationId", str(m.correlationId)),
    ("causationId", optStr(m.causationId)),
  ])->JSON.Encode.object

// Same subset, read out of a stored aggregate envelope (which is raw JSON, not
// a decoded `Message.meta`).
let metaJsonFromEnvelope = (envelope: Dict.t<JSON.t>): JSON.t => {
  let m = envelope->Dict.get("meta")->Option.flatMap(JSON.Decode.object)->Option.getOr(Dict.make())
  let get = k => m->Dict.get(k)->Option.flatMap(JSON.Decode.string)
  Dict.fromArray([
    ("service", get("service")->Option.getOr("")->str),
    ("time", get("time")->Option.getOr("")->str),
    ("user", get("user")->optStr),
    ("msgId", get("msgId")->Option.getOr("")->str),
    ("correlationId", get("correlationId")->Option.getOr("")->str),
    ("causationId", get("causationId")->optStr),
  ])->JSON.Encode.object
}

let recordJson = (r: record): JSON.t =>
  Dict.fromArray([
    ("position", str(r.position)),
    ("eventType", str(r.eventType)),
    ("payload", r.payload),
    (
      "tags",
      r.tags
      ->Array.map(t =>
        Dict.fromArray([("key", str(t.key)), ("value", str(t.value))])->JSON.Encode.object
      )
      ->JSON.Encode.array,
    ),
    ("meta", r.meta),
    ("recordedAt", str(r.recordedAt)),
  ])->JSON.Encode.object

// ── Filter arguments ─────────────────────────────────────────────────────────

type filter = {
  entityId?: string,
  tagKey?: string,
  tagValue?: string,
  eventTypes?: array<string>,
  user?: string,
  timeFrom?: string,
  timeTo?: string,
}

let readFilter = (args: JSON.t): filter => {
  let f =
    args
    ->JSON.Decode.object
    ->Option.flatMap(d => d->Dict.get("filter"))
    ->Option.flatMap(JSON.Decode.object)
    ->Option.getOr(Dict.make())
  let s = k => f->Dict.get(k)->Option.flatMap(JSON.Decode.string)
  {
    entityId: ?s("entityId"),
    tagKey: ?s("tagKey"),
    tagValue: ?s("tagValue"),
    eventTypes: ?f
    ->Dict.get("eventTypes")
    ->Option.flatMap(JSON.Decode.array)
    ->Option.map(a => a->Array.filterMap(JSON.Decode.string)),
    user: ?s("user"),
    timeFrom: ?s("timeFrom"),
    timeTo: ?s("timeTo"),
  }
}

// The tag a caller means: the precise (tagKey, tagValue) pair when given,
// otherwise the `entityId` shortcut matched against ANY tag value.
let matchesTag = (r: record, f: filter): bool =>
  switch (f.tagKey, f.tagValue) {
  | (Some(k), Some(v)) => r.tags->Array.some(t => t.key == k && t.value == v)
  | (None, Some(v)) => r.tags->Array.some(t => t.value == v)
  | (Some(k), None) => r.tags->Array.some(t => t.key == k)
  | (None, None) =>
    switch f.entityId {
    | Some(id) => r.tags->Array.some(t => t.value == id)
    | None => true
    }
  }

let matchesFilter = (r: record, f: filter): bool => {
  let userOf = () =>
    r.meta->JSON.Decode.object->Option.flatMap(d => d->Dict.get("user"))->Option.flatMap(JSON.Decode.string)
  let timeOf = () =>
    r.meta
    ->JSON.Decode.object
    ->Option.flatMap(d => d->Dict.get("time"))
    ->Option.flatMap(JSON.Decode.string)
    ->Option.getOr(r.recordedAt)
  matchesTag(r, f) &&
  f.eventTypes->Option.mapOr(true, types => types->Array.includes(r.eventType)) &&
  f.user->Option.mapOr(true, u => userOf() == Some(u)) &&
  f.timeFrom->Option.mapOr(true, from => timeOf() >= from) &&
  f.timeTo->Option.mapOr(true, to_ => timeOf() <= to_)
}

// ── Pagination ───────────────────────────────────────────────────────────────
// Keyset over `position`, ascending (oldest first) — the natural reading order
// for a history. Reuses QueryDbListQuery's connection builder so edges,
// cursors and pageInfo are byte-identical in shape to every other connection
// in the API, so existing client pagination applies unchanged.

let paginate = (~records: array<record>, ~args: JSON.t): JSON.t => {
  let argsDict = args->JSON.Decode.object->Option.getOr(Dict.make())
  let getInt = k =>
    argsDict->Dict.get(k)->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt)
  let getStr = k => argsDict->Dict.get(k)->Option.flatMap(JSON.Decode.string)

  let sorted = records->Array.toSorted((a, b) => comparePosition(a.position, b.position))

  let first = getInt("first")
  let last = getInt("last")
  let after = getStr("after")
  let before = getStr("before")
  let isBackward = last->Option.isSome

  let bounded = switch (after, before) {
  | (Some(c), _) if !isBackward =>
    let cv = QueryDbListQuery.decodeCursor(c)
    sorted->Array.filter(r => positionGt(r.position, cv))
  | (_, Some(c)) if isBackward =>
    let cv = QueryDbListQuery.decodeCursor(c)
    sorted->Array.filter(r => positionLt(r.position, cv))
  | _ => sorted
  }

  let pageSize = (isBackward ? last : first)->Option.getOr(QueryDbListQuery.defaultListPageSize)
  let take = pageSize + 1
  let (pageItems, hasMore) = if isBackward {
    let len = bounded->Array.length
    let startIdx = len > take ? len - take : 0
    let arr = bounded->Array.slice(~start=startIdx, ~end=len)
    let hasMore = arr->Array.length > pageSize
    (hasMore ? arr->Array.slice(~start=1, ~end=arr->Array.length) : arr, hasMore)
  } else {
    let arr = bounded->Array.slice(~start=0, ~end=take)
    let hasMore = arr->Array.length > pageSize
    (arr->Array.slice(~start=0, ~end=pageSize), hasMore)
  }

  QueryDbListQuery.buildConnection(
    ~pageItems=pageItems->Array.map(recordJson),
    ~hasNextPage=!isBackward && hasMore,
    ~hasPreviousPage=isBackward && hasMore,
    ~cursorValueOf=item =>
      item
      ->JSON.Decode.object
      ->Option.flatMap(d => d->Dict.get("position"))
      ->Option.flatMap(JSON.Decode.string)
      ->Option.getOr(""),
  )
}

let emptyConnection = () =>
  QueryDbListQuery.buildConnection(
    ~pageItems=[],
    ~hasNextPage=false,
    ~hasPreviousPage=false,
    ~cursorValueOf=_ => "",
  )

module Make = (Bus: LocalBus.T) => {
  let log = Logger.fromEnv()

  // A DCB read narrowed to the caller's tag whenever one was supplied. Pushing
  // the tag into the query means only the unfiltered plugin-wide sweep — the
  // rare case — ever reads broadly; the audit-trail case reads just its entity.
  let dcbQueryFor = (f: filter): Reventless.DcbTag.query =>
    switch (f.tagKey, f.tagValue, f.entityId) {
    | (Some(k), Some(v), _) => [{tags: [{key: k, value: v}]}]
    | _ => []
    }

  let readDcb = async (
    read: (
      ~query: Reventless.DcbTag.query,
      ~after: Reventless.DcbTag.sequencePosition=?,
    ) => promise<ReventlessCore.DcbEventLog_Adapter.rawReadResult>,
    f: filter,
  ) => {
    let result = await read(~query=dcbQueryFor(f), ~after=?None)
    result.ReventlessCore.DcbEventLog_Adapter.events->Array.map(e => {
      position: e.position,
      eventType: e.eventType,
      payload: e.data,
      tags: e.tags,
      meta: metaJson(e.meta),
      recordedAt: e.recordedAt,
    })
  }

  // Aggregate logs replay per entity and return the stored `{id, meta, event}`
  // envelopes in seq order, so the array index IS the sequence position.
  let readAggregate = async (~replay, ~entityId) => {
    let envelopes = await replay(entityId)
    envelopes->Array.mapWithIndex((json, i) => {
      let obj = json->JSON.Decode.object->Option.getOr(Dict.make())
      let event = obj->Dict.get("event")->Option.getOr(JSON.Encode.null)
      let id =
        obj->Dict.get("id")->Option.flatMap(JSON.Decode.string)->Option.getOr(entityId)
      let meta = metaJsonFromEnvelope(obj)
      let time =
        meta
        ->JSON.Decode.object
        ->Option.flatMap(d => d->Dict.get("time"))
        ->Option.flatMap(JSON.Decode.string)
        ->Option.getOr("")
      {
        position: i->Int.toString,
        eventType: Reventless.Message.variantNameOfJson(event),
        payload: event,
        tags: [{Reventless.DcbTag.key: "id", value: id}],
        meta,
        // An aggregate log stores no separate storage timestamp — producer
        // time is the only one there is.
        recordedAt: time,
      }
    })
  }

  let register = (
    ~server: ReventlessGraphqlServer.GraphQL_ServerInstance.t,
    params: Plugin_Helpers.eventQueryRegistrationParams,
  ) => {
    let seen: Set.t<string> = Set.make()

    params.eventLogEntries->Array.forEach(entry => {
      let displayName = entry.displayName
      if !(seen->Set.has(displayName)) {
        seen->Set.add(displayName)
        let fieldName = Plugin_EventQuerySchema.historyFieldName(
          ~plugin=params.pluginName,
          ~displayName,
        )

        let resolver: ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn = async (
          _root,
          args,
          _ctx,
        ) => {
          let f = readFilter(args)
          let records = switch Bus.getEventLogReplay(entry.busKey) {
          | Some(replay) =>
            switch f.entityId {
            | Some(entityId) => await readAggregate(~replay, ~entityId)
            | None =>
              // Not a silent empty page: an aggregate log genuinely cannot be
              // read without an id, and a caller who omitted one asked a
              // question this log cannot answer.
              log.warn(
                ~comp="EventHistoryResolvers_GraphQL",
                `${fieldName}: ${displayName} is an aggregate event log — it can only be read per entity. Supply filter.entityId.`,
              )
              []
            }
          | None =>
            switch Bus.getDcbEventLogRead(entry.busKey) {
            | Some(read) => await readDcb(read, f)
            | None => []
            }
          }
          switch records {
          | [] => emptyConnection()
          | _ => paginate(~records=records->Array.filter(r => matchesFilter(r, f)), ~args)
          }
        }

        // The SDL comes from the same generator that produced the plugin
        // fragment's field, so the local server's schema and the fragment can
        // not disagree about arguments or return type. (The supporting types
        // reach the server separately, via `schemaTypeRegistrationHook` over
        // the fragment's `types`.)
        let sdlFields =
          Plugin_EventQuerySchema.generate(
            ~plugin=params.pluginName,
            ~eventLogEntries=[entry],
          ).queryFields

        server.registerQueries(~sdlFields, ~resolvers=Dict.fromArray([(fieldName, resolver)]))
      }
    })
  }
}
