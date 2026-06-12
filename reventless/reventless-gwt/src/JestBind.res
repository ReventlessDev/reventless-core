// Bridge between the runner-agnostic `Outcome.outcome` algebra and Jest.
//
// GWT DSLs emit `Outcome.outcome` from every `then*` combinator. Test files
// registered via `JestBind.test` / `JestBind.testPromise` have their body's
// outcome translated into a Jest pass/fail, unless the standalone CLI runner
// has activated its in-process `Collector` — in which case the call pushes
// straight into the collector and skips Jest. This lets the same test file
// run under either `pnpm jest` or `reventless-gwt run` without modification.
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
  if Collector.isActive() {
    Collector.pushDescribe(label, body)
  } else {
    JestGlobals.describe(label, body)
  }

let test = (~slice=?, name: string, body: unit => Outcome.outcome) =>
  if Collector.isActive() {
    let location = Collector.captureLocation(1)
    Collector.push(~slice?, ~location?, name, () => Promise.resolve(body()))
  } else {
    JestGlobals.testSync(name, () => assertOutcome(~slice?, body()))
  }

let testPromise = (
  ~slice=?,
  name: string,
  ~timeout: option<int>=?,
  body: unit => promise<Outcome.outcome>,
) =>
  if Collector.isActive() {
    let location = Collector.captureLocation(1)
    Collector.push(~slice?, ~location?, name, body)
  } else {
    switch timeout {
    | Some(t) =>
      JestGlobals.testWithTimeout(name, async () => assertOutcome(~slice?, await body()), t)
    | None => JestGlobals.testPromise(name, async () => assertOutcome(~slice?, await body()))
    }
  }
