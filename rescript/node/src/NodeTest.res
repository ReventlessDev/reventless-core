/** Bindings for [`node:test`](https://nodejs.org/api/test.html), the runner behind
    `node --test`.

    Only the forms a test file declares itself with. A test body is synchronous
    unless it is bound through {!testAsync}; a promise returned from {!test}'s body
    would not be awaited by the type, so the two are kept apart. */
@module("node:test")
external test: (string, unit => unit) => unit = "test"

@module("node:test")
external testAsync: (string, unit => promise<unit>) => unit = "test"

/** Whether a test runs, or why it is skipped. Node takes `false` or a reason
    string, and prints the reason beside the skipped test. */
@unboxed
type skip = | @as(false) Run | Skip(string)

type options = {skip?: skip}

/** A test that decides at load time whether it can run — one that needs a sibling
    checkout, say, and skips with a reason where there is none. */
@module("node:test")
external testWith: (string, options, unit => unit) => unit = "test"
