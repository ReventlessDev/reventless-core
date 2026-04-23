// Bridge between the runner-agnostic `Outcome.outcome` algebra and Jest.
//
// GWT DSLs emit `Outcome.outcome` from every `then*` combinator. Test files
// registered via `JestBind.test` / `JestBind.testPromise` have their body's
// outcome translated into a Jest pass/fail. This lets existing Jest
// infrastructure keep working during the migration (Stage 7 introduces the
// standalone CLI runner that consumes the same outcomes directly).
//
// `~slice` is the slice/component name — each DSL threads `Spec.name` through
// so failure hints read `Look at AddCategory.decide` rather than the generic
// `<slice>.decide` fallback.

let describe = Jest.describe

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

let test = (~slice=?, name: string, body: unit => Outcome.outcome) =>
  Jest.test(name, () => body()->toAssertion(~slice?))

let testPromise = (
  ~slice=?,
  name: string,
  ~timeout: option<int>=?,
  body: unit => promise<Outcome.outcome>,
) => Jest.testPromise(name, ~timeout?, async () => (await body())->toAssertion(~slice?))
