// Bridge between the runner-agnostic `Outcome.outcome` algebra and Jest.
//
// GWT DSLs emit `Outcome.outcome` from every `then*` combinator. Test files
// registered via `JestBind.test` / `JestBind.testPromise` have their body's
// outcome translated into a Jest pass/fail. This lets existing Jest
// infrastructure keep working during the migration (Stage 7 introduces the
// standalone CLI runner that consumes the same outcomes directly).
//
// Consumers keep their existing `describe`/`test` call sites — only the
// **return type** of the body changes, from `Jest.assertion` to `Outcome.outcome`
// (or `promise<Outcome.outcome>`). Because test bodies usually terminate with
// a `->then*` chain, the body's return type is inferred from the chain and the
// call site needs no change.

let describe = Jest.describe

let toAssertion = (outcome: Outcome.outcome): Jest.assertion =>
  switch outcome {
  | Ok() => Jest.pass
  | Error(m) => {
      let hint = Hint.forMismatch(m)
      Jest.fail(`${Outcome.format(m)}\n\n${Hint.format(hint)}`)
    }
  }

let test = (name: string, body: unit => Outcome.outcome) =>
  Jest.test(name, () => body()->toAssertion)

let testPromise = (name: string, ~timeout: option<int>=?, body: unit => promise<Outcome.outcome>) =>
  Jest.testPromise(name, ~timeout?, async () => (await body())->toAssertion)
