// A stash in this process's memory: what the local platform provisions, since
// the door that puts and the slice that takes run in one process there.
//
// Lost on a restart, which is the right failure for what it holds: a restart
// between a person submitting a form and the slice acting on it leaves them to
// submit it again, and leaves no secret on disk.

type entry = {value: string, expiresAt: float}

/** A fresh, empty stash. `now` is injected so a test can move time instead of
    waiting for it. */
let make = (~now: unit => float=Date.now): Reventless.Stash.t => {
  let held: dict<entry> = Dict.make()
  // Expired entries are dropped on every call, so nothing a person abandoned
  // outlives its time by more than the next request.
  let sweep = () => {
    let at = now()
    held
    ->Dict.toArray
    ->Array.forEach(((key, {expiresAt})) => expiresAt <= at ? held->Dict.delete(key) : ())
  }
  {
    put: async (~key, ~value, ~ttl) => {
      sweep()
      held->Dict.set(key, {value, expiresAt: now() +. Int.toFloat(ttl) *. 1000.})
      Ok()
    },
    take: async (~key) => {
      sweep()
      let found = held->Dict.get(key)->Option.map(e => e.value)
      held->Dict.delete(key)
      Ok(found)
    },
  }
}
