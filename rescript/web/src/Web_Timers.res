// Bindings for the timer globals.
//
// Handles are abstract rather than `float`. Node returns a Timeout *object*
// and browsers return a number, so `float` is a lie on the server — it happens
// to work only because the value is passed straight back to `clearTimeout`.
// An opaque type says exactly that: the handle is for cancelling, nothing else.

type timeoutId
type intervalId

/** Delays are milliseconds. */
@val external setTimeout: (unit => unit, int) => timeoutId = "setTimeout"
@val external clearTimeout: timeoutId => unit = "clearTimeout"

@val external setInterval: (unit => unit, int) => intervalId = "setInterval"
@val external clearInterval: intervalId => unit = "clearInterval"

/** A promise that resolves after `ms` — the shape most callers actually want
    from `setTimeout`, and the one everybody re-implements. */
let delay = (ms: int): promise<unit> =>
  Promise.make((resolve, _) => {
    let _ = setTimeout(() => resolve(), ms)
  })
