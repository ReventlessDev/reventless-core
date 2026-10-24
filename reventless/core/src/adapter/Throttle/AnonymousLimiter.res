// Counts requests per door and source in fixed windows, and says whether one
// more is admitted. In memory: what a single process serving the doors needs.
//
// Fixed windows rather than sliding ones. A burst straddling a boundary can
// reach twice the limit, which bounds the abuse by a constant and keeps the
// state one counter per key.

type window = {startedAt: float, count: int}

type t = {admit: (~door: string, ~source: string) => bool}

/** A limiter for `limit`. `now` is injected so a test moves time instead of
    waiting for it. */
let make = (~limit: Reventless.AnonymousRequestLimit.t, ~now: unit => float=Date.now): t => {
  let windows: dict<window> = Dict.make()
  let length = Int.toFloat(limit.windowSeconds) *. 1000.
  {
    admit: (~door, ~source) => {
      let key = `${door}\u0000${source}`
      let at = now()
      // Expired windows are dropped as they are met, so the map holds only the
      // sources seen within the last window.
      windows
      ->Dict.toArray
      ->Array.forEach(((k, w)) => at -. w.startedAt >= length ? windows->Dict.delete(k) : ())
      switch windows->Dict.get(key) {
      | Some(w) if w.count >= limit.requests => false
      | Some(w) =>
        windows->Dict.set(key, {...w, count: w.count + 1})
        true
      | None =>
        windows->Dict.set(key, {startedAt: at, count: 1})
        true
      }
    },
  }
}
