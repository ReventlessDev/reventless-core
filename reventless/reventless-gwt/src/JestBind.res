// Bridge between the runner-agnostic `Outcome.outcome` algebra and Jest.
//
// GWT DSLs emit `Outcome.outcome` from every `then*` combinator. Test files
// registered via `JestBind.test` / `JestBind.testPromise` have their body's
// outcome translated into a Jest pass/fail, unless an external runner has
// registered an in-process sink (`RunnerHook`) — in which case the call is
// routed to that sink and skips Jest. This lets the same test file run under
// either plain `jest` or an external GWT runner without modification.
//
// `~slice` is the slice/component name — each DSL threads `Spec.name` through
// so failure hints read `Look at AddCategory.decide` rather than the generic
// `<slice>.decide` fallback.
//
// The Jest arm binds directly to Jest's globals via @reventlessdev/rescript-jest
// (module `JestGlobals`) with throwing semantics: a passing outcome is a no-op,
// a failing one throws a JS Error whose message Jest reports. (Jest's built-in
// `fail(msg)` was removed in Jest 27+ ESM mode — the mode these tests run under
// — so throwing is the portable way to fail a test.)

// Translate an outcome into Jest's throwing model: Ok is a no-op, Error throws
// the formatted mismatch + hint so Jest reports it as the failure message.
let assertOutcome = (~slice=?, outcome: Outcome.outcome): unit =>
  switch outcome {
  | Ok() => ()
  | Error(m) => {
      let hint = Hint.forMismatch(~slice?, m)
      JsError.throwWithMessage(`${Outcome.format(m)}\n\n${Hint.format(hint)}`)
    }
  }

let describe = (label: string, body: unit => unit) =>
  switch RunnerHook.get() {
  | Some(sink) => sink.describe(label, body)
  | None => JestGlobals.describe(label, body)
  }

// Pending-spec placeholder emitted by the codegen for slices with no upstream
// specification. Registers a non-running, non-failing entry under both drivers.
let todo = (label: string) =>
  switch RunnerHook.get() {
  | Some(sink) => sink.todo(label)
  | None => JestGlobals.todo(label)
  }

let test = (~slice=?, name: string, body: unit => Outcome.outcome) =>
  switch RunnerHook.get() {
  | Some(sink) =>
    let location = sink.captureLocation(1)
    sink.test(~slice?, ~location?, name, () => Promise.resolve(body()))
  | None => JestGlobals.testSync(name, () => assertOutcome(~slice?, body()))
  }

let testPromise = (
  ~slice=?,
  name: string,
  ~timeout: option<int>=?,
  body: unit => promise<Outcome.outcome>,
) =>
  switch RunnerHook.get() {
  | Some(sink) =>
    let location = sink.captureLocation(1)
    sink.test(~slice?, ~location?, ~timeout?, name, body)
  | None =>
    switch timeout {
    | Some(t) =>
      JestGlobals.testWithTimeout(name, async () => assertOutcome(~slice?, await body()), t)
    | None => JestGlobals.testPromise(name, async () => assertOutcome(~slice?, await body()))
    }
  }
