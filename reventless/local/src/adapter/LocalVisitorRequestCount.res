// The local platform's counting of visitor requests, in the view of them
// (`Reventless.VisitorRequestCount`): each request read, added to and written back
// in its minute's row and its hour's, one request at a time so that two at once do
// not lose a count. A count that fails is logged and dropped; the request never
// waits on it.

module C = Reventless.VisitorRequestCount

let log = ReventlessCore.Logger.fromEnv()

let rowOf = (json: JSON.t): option<C.row> =>
  try Some(Reventless.Util_Sury.fromJson(json, C.rowSchema)) catch {
  | _ => None
  }

let add = (row: C.row, ~admitted: bool): C.row => {
  ...row,
  requests: row.requests->Option.getOr(0) + 1,
  refused: row.refused->Option.getOr(0) + (admitted ? 0 : 1),
}

let countIn = async (ops: ReventlessCore.QueryDb_Adapter.operations, ~kind, ~admitted, ~at) =>
  await C.bucketsAt(at)->Array.reduce(Promise.resolve(), async (before, (seconds, start)) => {
    await before
    let id = C.idOf(~kind, ~seconds, ~start)
    let current = switch await ops.load(id) {
    | Ok(rows) => rows->Array.get(0)->Option.flatMap(rowOf)
    | Error(_) => None
    }
    let row = current->Option.getOr(C.empty(~kind, ~seconds, ~start))->add(~admitted)
    let _ = await ops.save(id, Reventless.Util_Sury.toJson(row, C.rowSchema), Overwrite, None)
  })

/** A recorder over the view `ops` finds, for the local limiter. Counts nothing
    while the view is not there. */
let make = (~ops: unit => option<ReventlessCore.QueryDb_Adapter.operations>) => {
  let queue = ref(Promise.resolve())
  (~kind: Reventless.AnonymousRequestLimit.kind, ~admitted: bool) =>
    switch ops() {
    | None => ()
    | Some(ops) =>
      let at = Date.make()
      queue :=
        queue.contents
        ->Promise.then(() => countIn(ops, ~kind=C.kindName(kind), ~admitted, ~at))
        ->Promise.catch(exn => {
          log.warn(
            ~comp="VisitorRequestCount",
            `a visitor's request was not counted: ${exn
              ->JsExn.fromException
              ->Option.flatMap(JsExn.message)
              ->Option.getOr("the view did not answer")}`,
          )
          Promise.resolve()
        })
    }
}
