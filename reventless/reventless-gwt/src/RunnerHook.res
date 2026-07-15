// Registration seam that lets an external runner intercept GWT test
// registration in-process instead of forwarding to Jest.
//
// By default no runner is registered, so `JestBind` forwards every
// `describe` / `test` / `testPromise` to Jest's globals — the workflow the
// example apps use (`npx jest`), unchanged. An external runner may register an
// in-process sink at startup; `JestBind` then routes each registration to the
// sink instead, so the same `*_GWT.res` file runs unmodified under either
// driver.

type location = {
  file: string,
  line: int,
  column: int,
}

type sink = {
  describe: (string, unit => unit) => unit,
  todo: string => unit,
  // Capture the caller's source location by walking the current stack, skipping
  // `n` internal frames. Invoked directly from `JestBind` so the resolved frame
  // is the user's test file (the skip count is tuned for that call site).
  captureLocation: int => option<location>,
  test: (
    ~slice: string=?,
    ~location: location=?,
    ~timeout: int=?,
    string,
    unit => promise<Outcome.outcome>,
  ) => unit,
}

// The currently-registered sink, if any. `None` → plain Jest behaviour.
let current: ref<option<sink>> = ref(None)

let register = (s: sink) => current := Some(s)
let reset = () => current := None
let get = () => current.contents
