/** Bindings for [`node:assert/strict`](https://nodejs.org/api/assert.html#strict-assertion-mode).

    The strict module only: `equal` is `===` and `deepEqual` is `deepStrictEqual`,
    so a test cannot pass on a coercion. Each assertion that takes a message has a
    `…Msg` form; the message replaces Node's generated one when the assertion
    fails, so it should say what went wrong rather than restate the values. */
@module("node:assert/strict")
external equal: ('a, 'a) => unit = "equal"

@module("node:assert/strict")
external equalMsg: ('a, 'a, string) => unit = "equal"

@module("node:assert/strict")
external deepEqual: ('a, 'a) => unit = "deepEqual"

@module("node:assert/strict")
external deepEqualMsg: ('a, 'a, string) => unit = "deepEqual"

@module("node:assert/strict")
external ok: bool => unit = "ok"

@module("node:assert/strict")
external okMsg: (bool, string) => unit = "ok"

/** `assert.match`, renamed because `match` is not an identifier in ReScript. */
@module("node:assert/strict")
external matches: (string, RegExp.t) => unit = "match"

@module("node:assert/strict")
external doesNotMatch: (string, RegExp.t) => unit = "doesNotMatch"

/** Always throws, so it types as any value — usable as the arm of a `switch` that
    has nothing to return. */
@module("node:assert/strict")
external fail: string => 'a = "fail"
