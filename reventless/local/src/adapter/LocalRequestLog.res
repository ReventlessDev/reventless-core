// One log line per GraphQL operation the app's API answers: a query or a subscription at debug, a
// mutation at info, one that answered with errors at warn, so it shows among the problems.

module YG = GraphqlYoga
module L = ReventlessCore.Logger

type line = {level: L.level, message: string, data: JSON.t}

let lineOf = (r: YG.requestReport): line => {
  let name = switch (r.operationName, r.fields) {
  | (Some(n), _) => n
  | (None, []) => "(anonymous)"
  | (None, fields) => fields->Array.join(", ")
  }
  let who = r.user->Option.mapOr("", u => ` by ${u}`)
  let took = r.kind == "subscription" ? "" : ` in ${r.ms->Float.toString} ms`
  let message = switch r.errors->Array.get(0) {
  | None => `${r.kind} ${name}${who}${took}`
  | Some(first) =>
    let more = r.errors->Array.length - 1
    `${r.kind} ${name}${who} failed${took}: ${first}${more > 0
        ? ` (and ${more->Int.toString} more)`
        : ""}`
  }
  let level: L.level = if r.errors != [] {
    Warn
  } else if r.kind == "mutation" {
    Info
  } else {
    Debug
  }
  let data = JSON.Encode.object(
    Dict.fromArray(
      [
        ("operation", JSON.Encode.string(r.kind)),
        ("fields", JSON.Encode.array(r.fields->Array.map(JSON.Encode.string))),
        ("ms", JSON.Encode.float(r.ms)),
      ]
      ->Array.concat(
        r.operationName->Option.mapOr([], n => [("operationName", JSON.Encode.string(n))]),
      )
      ->Array.concat(r.user->Option.mapOr([], u => [("user", JSON.Encode.string(u))]))
      ->Array.concat(
        r.errors == []
          ? []
          : [("errors", JSON.Encode.array(r.errors->Array.map(JSON.Encode.string)))],
      ),
    ),
  )
  {level, message, data}
}

/** The plugin that writes the line under the API's component, its fields as the line's detail
    rather than in its words. */
let plugin = (): YG.plugin =>
  YG.requestLog(r => {
    let {level, message, data} = lineOf(r)
    let comp = "GraphQL:Domain"
    if L.shouldLog(level, ~comp, ()) {
      L.emit(~level, ~comp, ~detail=data, message)
    }
  })
