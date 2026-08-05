// Log formatting utilities for domain objects.
//
// Three verbosity levels per domain object, each with singular + plural:
//
//   Commands (Message.commandJson):
//     cmdName      → "Add"                    cmdNames      → "[Add,Remove]"
//     cmdSummary   → "Add(1)"                 cmdSummaries  → "[Add(1),Remove(2)]"
//     cmdDetail    → "Add(1, {name:"Cat 1"})" cmdDetails    → "[Add(1, {...}), ...]"
//     cmdFull      → "{cmd+meta+id}"           cmdFulls      → "[{...}, ...]"
//
//   Events (JSON.t event' envelope):
//     eventName    → "Added"                  eventNames    → "[Added,Removed]"
//     eventSummary → "Added(1)"               eventSummaries → "[Added(1),Removed(2)]"
//     eventDetail  → "Added(1, {name:"Cat 1"})" eventDetails → "[Added(1, {...}), ...]"
//     eventFull    → "{evt+meta+id}"            eventFulls   → "[{...}, ...]"
//
//   Actions (Projection.action):
//     actionName   → "Create"                 actionNames   → "[Create,Update]"
//     actionDetail → "Create(order-1)"        actionDetails → "[Create(order-1),Update(order-2)]"
//
//   Other:
//     fmtState → "state=Order(order-1) seq=42"
//     fmtExn   → "err=<message>"

// ─── Style ───────────────────────────────────────────────────────────────────

// Re-exported so downstream callers in reventless-core can reach the shared
// styling primitive through `LogFormat.bold` rather than the spec namespace.
let bold = Reventless.AnsiStyle.bold

// ─── Value truncation ────────────────────────────────────────────────────────

@val external logEnv: dict<string> = "process.env"

/**
Per-value character budget for rendered payloads, before the rest is elided.

A detail line exists to say *which* command or event this is, not to reproduce
it: a single field can be arbitrarily large (a plugin structure, a pasted
document, an inline offload payload), and one of those turns a log into
something no one reads. Truncation is per value rather than per line so a large
field costs its neighbours nothing — the small fields that identify the message
stay visible next to it.

`REVENTLESS_LOG_MAX_VALUE` overrides the budget; `0` disables truncation for a
session that genuinely needs the whole payload.
*/
let maxValueChars =
  logEnv
  ->Dict.get("REVENTLESS_LOG_MAX_VALUE")
  ->Option.flatMap(v => Int.fromString(v))
  ->Option.getOr(512)

/** `s` capped at `maxValueChars`, with what was dropped named rather than
    silently missing — a truncated line must not read like a complete one. */
let truncate = (s: string): string => {
  let len = s->String.length
  if maxValueChars <= 0 || len <= maxValueChars {
    s
  } else {
    `${s->String.slice(~start=0, ~end=maxValueChars)}…(+${(len - maxValueChars)
      ->Int.toString} chars)`
  }
}

// ─── Commands ────────────────────────────────────────────────────────────────

// "Add"  (bold)
let cmdName = (msg: Message.commandJson): string =>
  msg.commandJson->Message.variantNameOfJson->bold

// "[Add,Remove]"
let cmdNames = (msgs: array<Message.commandJson>): string =>
  `[${msgs->Array.map(cmdName)->Array.join(",")}]`

// "Add(1)"
let cmdSummary = (msg: Message.commandJson): string =>
  `${msg->cmdName}(${msg.id})`

// "[Add(1),Remove(2)]"
let cmdSummaries = (msgs: array<Message.commandJson>): string =>
  `[${msgs->Array.map(cmdSummary)->Array.join(",")}]`

/**
`JSON.stringify` is typed as total but returns `undefined` — not a string — for
the one value `JSON.t` cannot represent: the `undefined` a ReScript record's
*absent* optional field leaves behind as an own property of the JS object. Read
the result as nullable so an absent field is dropped instead of reaching a
string function as `undefined`. An explicit `null` still stringifies to `"null"`
and keeps printing.
*/
external stringifiedOrAbsent: string => Nullable.t<string> = "%identity"

// Strip TAG from a variant JSON, return remaining fields as a compact string.
// {"TAG":"Add","name":"Cat 1"} → {name:"Cat 1"}
// "Add" (bare string variant) → ""
let variantFields = (json: JSON.t): string =>
  switch json {
  | Object(dict) =>
    let fields =
      dict
      ->Dict.toArray
      ->Array.filter(((k, _)) => k != "TAG")
      ->Array.filterMap(((k, v)) =>
        v
        ->JSON.stringify
        ->stringifiedOrAbsent
        ->Nullable.toOption
        ->Option.map(s => `${k}:${s->truncate}`)
      )
      ->Array.join(",")
    fields == "" ? "" : `, {${fields}}`
  | _ => ""
  }

// "Add(1, {name:"Cat 1"})"  (ReScript-style variant rendering)
let cmdDetail = (msg: Message.commandJson): string =>
  `${msg->cmdName}(${msg.id}${msg.commandJson->variantFields})`

// "[Add(1, {name:"Cat 1"}), Remove(2)]"
let cmdDetails = (msgs: array<Message.commandJson>): string =>
  `[${msgs->Array.map(cmdDetail)->Array.join(", ")}]`

// "Add({name:"Cat 1"})"  — like cmdDetail but WITHOUT the leading id. Used by DCB
// command logs where the id is a partition-tag value already shown among the
// fields, so a `(id)` prefix would just duplicate it.
let cmdLabelOfJson = (json: JSON.t): string => {
  let fields = json->variantFields
  let body =
    fields->String.startsWith(", ")
      ? fields->String.slice(~start=2, ~end=fields->String.length)
      : fields
  `${json->Message.variantNameOfJson->bold}(${body})`
}

// "Add({name:"Cat 1"})"  — cmdLabelOfJson for a full command envelope.
let cmdDetailNoId = (msg: Message.commandJson): string => msg.commandJson->cmdLabelOfJson

// "{\"command\":{...},\"meta\":{...},\"id\":\"1\"}"  (full envelope with meta, no summary prefix)
let cmdFull = (msg: Message.commandJson): string => {
  let commandStr = msg.commandJson->JSON.stringify
  let metaStr = msg.meta->Message.encode(Message.metaSchema)->JSON.stringify
  `{"command":${commandStr},"meta":${metaStr},"id":"${msg.id}"}`
}

// "[Add(1): {\"command\":...,\"meta\":...}, ...]"
let cmdFulls = (msgs: array<Message.commandJson>): string =>
  `[${msgs->Array.map(cmdFull)->Array.join(", ")}]`

// ─── Events (JSON.t event' envelope) ─────────────────────────────────────────

// "Added"  (bold)
let eventName = (j: JSON.t): string =>
  j->Message.eventNameOfEvent'Json->bold

// "[Added,Removed]"
let eventNames = (events: array<JSON.t>): string =>
  `[${events->Array.map(eventName)->Array.join(",")}]`

// "Added(1)"
let eventSummary = (j: JSON.t): string => {
  let (id, _, _) = j->Message.idMetaEventOfEvent'Json
  `${j->eventName}(${id})`
}

// "[Added(1),Removed(2)]"
let eventSummaries = (events: array<JSON.t>): string =>
  `[${events->Array.map(eventSummary)->Array.join(",")}]`

// "Added(1, {name:"Cat 1"})"  (ReScript-style variant rendering)
let eventDetail = (j: JSON.t): string => {
  let (id, _, _) = j->Message.idMetaEventOfEvent'Json
  let eventJson =
    j->JSON.Decode.object->Option.flatMap(d => d->Dict.get("event"))->Option.getOr(JSON.Encode.null)
  `${j->eventName}(${id}${eventJson->variantFields})`
}

// "[Added(1, {name:"Cat 1"}), Removed(2)]"
let eventDetails = (events: array<JSON.t>): string =>
  `[${events->Array.map(eventDetail)->Array.join(", ")}]`

// "{\"event\":{...},\"meta\":{...},\"id\":\"1\"}"  (full envelope with meta, no summary prefix)
let eventFull = (j: JSON.t): string => {
  let (id, metaStr, eventStr) = j->Message.idMetaEventOfEvent'Json
  `{"event":${eventStr},"meta":${metaStr},"id":"${id}"}`
}

// "[Added(1): {\"event\":...,\"meta\":...}, ...]"
let eventFulls = (events: array<JSON.t>): string =>
  `[${events->Array.map(eventFull)->Array.join(", ")}]`

// ─── Actions (Projection.action) ─────────────────────────────────────────────

// "Create"
let actionName = (action: Reventless.Projection.action<'id, 'state>): string =>
  switch action {
  | Create(_, _) => "Create"
  | CreateMany(_) => "CreateMany"
  | CreateMultiState(_, _) => "CreateMultiState"
  | Update(_, _) => "Update"
  | UpdateMany(_, _) => "UpdateMany"
  | UpdateWithDefault(_, _, _) => "UpdateWithDefault"
  | UpdateManyWithDefault(_, _, _) => "UpdateManyWithDefault"
  | UpdateMultiState(_, _) => "UpdateMultiState"
  | UpdateManyMultiStates(_, _) => "UpdateManyMultiStates"
  | Set(_, _) => "Set"
  | SetMany(_, _) => "SetMany"
  | Delete(_) => "Delete"
  | DeleteMany(_) => "DeleteMany"
  | DeleteIf(_, _) => "DeleteIf"
  | DeleteManyIf(_, _) => "DeleteManyIf"
  | Ignore => "Ignore"
  }

// "[Create,Update,Delete]"
let actionNames = (actions: array<Reventless.Projection.action<'id, 'state>>): string =>
  `[${actions->Array.map(actionName)->Array.join(",")}]`

// "Create(order-1)" — includes id where the variant carries one
let actionDetail = (action: Reventless.Projection.action<string, 'state>): string =>
  switch action {
  | Create(id, _) => `Create(${id})`
  | CreateMany(items) => `CreateMany(${items->Array.length->Int.toString})`
  | CreateMultiState(id, _) => `CreateMultiState(${id})`
  | Update(id, _) => `Update(${id})`
  | UpdateMany(ids, _) => `UpdateMany(${ids->Array.length->Int.toString})`
  | UpdateWithDefault(id, _, _) => `UpdateWithDefault(${id})`
  | UpdateManyWithDefault(ids, _, _) => `UpdateManyWithDefault(${ids->Array.length->Int.toString})`
  | UpdateMultiState(id, _) => `UpdateMultiState(${id})`
  | UpdateManyMultiStates(ids, _) => `UpdateManyMultiStates(${ids->Array.length->Int.toString})`
  | Set(id, _) => `Set(${id})`
  | SetMany(ids, _) => `SetMany(${ids->Array.length->Int.toString})`
  | Delete(id) => `Delete(${id})`
  | DeleteMany(ids) => `DeleteMany(${ids->Array.length->Int.toString})`
  | DeleteIf(id, _) => `DeleteIf(${id})`
  | DeleteManyIf(ids, _) => `DeleteManyIf(${ids->Array.length->Int.toString})`
  | Ignore => "Ignore"
  }

// "[Create(order-1),Update(order-2)]"
let actionDetails = (actions: array<Reventless.Projection.action<string, 'state>>): string =>
  `[${actions->Array.map(actionDetail)->Array.join(",")}]`

// ─── Other ───────────────────────────────────────────────────────────────────

// "state=Order(order-1) seq=42"
let fmtState = (~name: string, ~id: string, ~seq: int): string =>
  `state=${name}(${id}) seq=${seq->Int.toString}`

// "err=<message>"
let fmtExn = (e: exn): string =>
  `err=${e->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")}`

// ─── Legacy aliases (kept for existing callers) ──────────────────────────────

let commandJsonToLogMessage = cmdFull
let commandJsonsToLogMessages: array<Message.commandJson> => array<string> = cmdJsons => {
  let count = cmdJsons->Array.length->Int.toString
  cmdJsons->Array.mapWithIndex((cmdJson, idx) => {
    let idx = (idx + 1)->Int.toString
    `${idx}/${count}: ${cmdJson->cmdSummary}: ${cmdJson->cmdFull}`
  })
}
let event'JsonToLogMessage = (j: JSON.t): string =>
  `${j->eventSummary}: ${j->eventFull}`

// Legacy concise aliases
let fmtCmd = cmdSummary
let fmtCmds = (msgs: array<Message.commandJson>): string =>
  `cmds=${msgs->Array.length->Int.toString} [${msgs->Array.map(cmdName)->Array.join(",")}]`
let fmtEventJson = eventSummary
let fmtAction = actionName
let fmtActions = actionNames
