// Counting a visitor's request in the plugin's view of visitor request counts, as
// the command function does: one atomic add to the row of the request's minute,
// one to its hour, each kept for its bucket's time, and one to the row of every
// request, kept for good. A request is counted
// while the limit is asked, and counted as refused after, where it was. The view's
// table is `VISITOR_REQUEST_COUNTS_TABLE`; without one nothing is counted. A count
// that fails is logged and never fails the request.

let tableVariable = "VISITOR_REQUEST_COUNTS_TABLE"

/** The view's rows expire by this attribute, as every view table's do. */
let expiryAttribute = Util_DynamoDb_Runtime.purgeTimeAttributeName

module C = Reventless.VisitorRequestCount

let log = ReventlessCore.Logger.fromEnv()

let addTo = async (~tableName, ~kind, ~field, ~seconds, ~start) => {
  let row = C.empty(~kind, ~seconds, ~start)
  let expiry = C.keptSeconds(seconds)->Option.map(kept => start +. Int.toFloat(kept))
  let names = Dict.fromArray([
    ("#count", field),
    ("#kind", "kind"),
    ("#startsAt", "startsAt"),
    ("#seconds", "seconds"),
  ])
  let values = Dict.fromArray([
    (":one", JSON.Encode.int(1)),
    (":kind", JSON.Encode.string(row.kind)),
    (":startsAt", JSON.Encode.string(row.startsAt)),
    (":seconds", JSON.Encode.int(seconds)),
  ])
  expiry->Option.forEach(at => {
    names->Dict.set("#expiry", expiryAttribute)
    values->Dict.set(":expiry", JSON.Encode.float(at))
  })
  let _ = await AwsSdk.DynamoDb_DocumentClient.UpdateCommand.make({
    tableName,
    key: Dict.fromArray([("id", JSON.Encode.string(C.idOf(~kind, ~seconds, ~start)))]),
    updateExpression: "ADD #count :one SET #kind = :kind, #startsAt = :startsAt, #seconds = :seconds" ++ (
      expiry->Option.isSome ? ", #expiry = :expiry" : ""
    ),
    expressionAttributeNames: names,
    expressionAttributeValues: values,
  })->AwsSdk.DynamoDb_DocumentClient.UpdateCommand.send
}

let count = async (~kind: Reventless.AnonymousRequestLimit.kind, ~field, ~now) =>
  switch NodeProcess.env->Dict.get(tableVariable) {
  | None | Some("") => ()
  | Some(tableName) =>
    try {
      let _ = await C.bucketsAt(now)
      ->Array.map(((seconds, start)) =>
        addTo(~tableName, ~kind=C.kindName(kind), ~field, ~seconds, ~start)
      )
      ->Promise.all
    } catch {
    | exn =>
      log.warn(
        ~comp="VisitorRequestCount",
        `a visitor's request was not counted: ${exn
          ->JsExn.fromException
          ->Option.flatMap(JsExn.message)
          ->Option.getOr("the table did not answer")}`,
      )
    }
  }

/** Counts one request of `kind` at `now`. */
let request = (~kind, ~now=Date.make()) => count(~kind, ~field="requests", ~now)

/** Counts one request of `kind` at `now` as one the limit refused. */
let refused = (~kind, ~now=Date.make()) => count(~kind, ~field="refused", ~now)
