// Source-level test filters: `only`, `skip`, `xtest`, `xdescribe`.
//
// Jest ships `describe.only` / `test.only` / `xtest` as properties/aliases
// on the globals; reventless-gwt exposes them as explicit helpers. When the
// CLI runner is active, they mutate `Collector` state; when Jest is driving,
// they forward to the Jest globals.

@val external jestXTest: (string, unit => unit) => unit = "xtest"
@val external jestXDescribe: (string, unit => unit) => unit = "xdescribe"

// Mark the next registered `test` / `testPromise` as skipped.
let skip = () => Collector.markSkipNext()

// Mark the next registered `test` / `testPromise` as the focus of the run.
// If at least one entry is flagged `Only`, only those entries execute.
let only = () => Collector.markOnlyNext()

// xtest: register a test but mark it as skipped.
let xtest = (~slice as _: option<string>=?, name: string, _body: unit => Outcome.outcome) =>
  if Collector.isActive() {
    Collector.markSkipNext()
    Collector.push(name, () => Promise.resolve(Outcome.pass))
  } else {
    jestXTest(name, () => ())
  }

// xdescribe: register a describe block with every nested test pre-marked
// skipped.
let xdescribe = (label: string, body: unit => unit) =>
  if Collector.isActive() {
    Collector.skipDepth := Collector.skipDepth.contents + 1
    // Decrement on both the normal and the throwing path (ReScript has no
    // `finally`): a body that raises must not leak the incremented depth and
    // skip every following sibling/file.
    try {
      Collector.pushDescribe(label, body)
      Collector.skipDepth := Collector.skipDepth.contents - 1
    } catch {
    | e =>
      Collector.skipDepth := Collector.skipDepth.contents - 1
      throw(e)
    }
  } else {
    jestXDescribe(label, body)
  }
