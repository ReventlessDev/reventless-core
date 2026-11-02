// The change a projection is writing, stamped on the rows it writes as `_change`: the flow,
// the event and the time. A projection runs each action `during` its change; the encoder
// that turns a row into JSON reads it back with `stampInto`. The value follows the call
// and what it awaits, so rows written at the same time each get their own.

/** The last change of a row: its flow, the event behind it, and when it was written. */
type t = {flow?: string, msgId: string, at: string}

/** The key a row carries it under; no state field may use it. */
let key = "_change"

let storage: NodeAsyncHooks.asyncLocalStorage<t> = NodeAsyncHooks.makeAsyncLocalStorage()

/** Runs `f` with `change` as the change its writes stamp. */
let during = (change: t, f: unit => 'a): 'a => storage->NodeAsyncHooks.run(change, f)

/** The change being written, outside a projection none. */
let current = (): option<t> => storage->NodeAsyncHooks.getStore

let toJson = (c: t): JSON.t =>
  [("msgId", JSON.Encode.string(c.msgId)), ("at", JSON.Encode.string(c.at))]
  ->Array.concat(c.flow->Option.mapOr([], f => [("flow", JSON.Encode.string(f))]))
  ->Dict.fromArray
  ->JSON.Encode.object

/** Adds the current change to a row about to be stored. */
let stampInto = (row: dict<JSON.t>) => current()->Option.forEach(c => row->Dict.set(key, toJson(c)))

/** The same for a row as JSON; a value that is not an object is left as it is. */
let stamp = (row: JSON.t): JSON.t =>
  switch (current(), row) {
  | (Some(c), JSON.Object(d)) =>
    let d = d->Dict.copy
    d->Dict.set(key, toJson(c))
    JSON.Object(d)
  | _ => row
  }
