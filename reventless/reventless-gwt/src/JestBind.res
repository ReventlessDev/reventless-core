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

// Jest's built-in `fail(msg)` global was removed in Jest 27+ ESM mode, which
// is the mode reventless-gwt's tests run under. Throwing a JS Error from the
// test body is the portable way to mark a test as failed — Jest catches it
// and reports the thrown message as the failure. `Jest.pass` still works
// as-is because `affirm(Ok)` is a no-op.
let toAssertion = (~slice=?, outcome: Outcome.outcome): Jest.assertion =>
  switch outcome {
  | Ok() => Jest.pass
  | Error(m) => {
      let hint = Hint.forMismatch(~slice?, m)
      JsError.throwWithMessage(`${Outcome.format(m)}\n\n${Hint.format(hint)}`)
    }
  }

let describe = (label: string, body: unit => unit) =>
  if Collector.isActive() {
    Collector.pushDescribe(label, body)
  } else {
    Jest.describe(label, body)
  }

let test = (~slice=?, name: string, body: unit => Outcome.outcome) =>
  if Collector.isActive() {
    let location = Collector.captureLocation(1)
    Collector.push(~slice?, ~location?, name, () => Promise.resolve(body()))
  } else {
    Jest.test(name, () => body()->toAssertion(~slice?))
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
    Jest.testPromise(name, ~timeout?, async () => (await body())->toAssertion(~slice?))
  }
