// CLI-mode binding for test files.
//
// Mirrors the shape of `JestBind` (`describe`, `test`, `testPromise`) but
// pushes directly into `Collector` instead of forwarding to Jest globals.
// Test files can either:
//
//   1. Rely on the DSL default (every `*_GWT.res` module uses `JestBind`
//      internally, which routes to `Collector` when the CLI has activated it),
//      or
//   2. Explicitly `open ReventlessGwt.Bind` to get these functions bound at
//      compile time — useful for ad-hoc harnesses or tests that want to
//      bypass the JestBind fallback entirely.
//
// Either way, the runtime contract is identical: each call pushes one entry
// into `Collector.entries`. The CLI drains the list after dynamic-import
// resolves.

let describe = (label: string, body: unit => unit) =>
  Collector.pushDescribe(label, body)

let test = (~slice=?, name: string, body: unit => Outcome.outcome) => {
  let location = Collector.captureLocation(1)
  Collector.push(~slice?, ~location?, name, () => Promise.resolve(body()))
}

let testPromise = (~slice=?, name: string, body: unit => promise<Outcome.outcome>) => {
  let location = Collector.captureLocation(1)
  Collector.push(~slice?, ~location?, name, body)
}
