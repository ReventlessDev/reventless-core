// Golden-output tests pinning the per-mismatch rendering of the three
// string-emitting formatters:
//   - `Outcome.format`               (used by the JUnit `<failure>` body)
//   - `FormatterHuman.renderMismatch` (terminal output)
//   - `FormatterTap.renderMismatchYaml` (TAP YAML diagnostic block)
//
// These three functions are exactly what the deferred `Outcome.mismatch`
// normalization (plan C4) will unify. Pinning their current output byte-for-byte
// lets that refactor prove it preserved Human/TAP rendering — and makes the
// deliberate JUnit change (it currently renders via raw `Outcome.format`, unlike
// the RenderRescript-based Human/TAP) explicit and reviewable rather than silent.
//
// The fixtures cover the structural variety the normalization must preserve:
// array expected/actual, the Error()/Ok() wrapping with a `None` actual, the
// `key` extra + option rendering, a single-sided actual, plain-string (non-JSON)
// expected/actual, and the `Throw` stack special case.

open JestGlobals

let evA = JSON.parseOrThrow(`{"TAG":"ProductAdded","_0":{"productId":"p1","name":"Widget"}}`)
let evB = JSON.parseOrThrow(`{"TAG":"ProductRenamed","_0":{"productId":"p1","name":"Gadget"}}`)
let stateActive = JSON.parseOrThrow(`{"status":"active"}`)
let stateArchived = JSON.parseOrThrow(`{"status":"archived"}`)

type golden = {
  name: string,
  mismatch: Outcome.mismatch,
  format: string,
  human: string,
  tap: string,
}

let goldens: array<golden> = [
  {
    name: "EventsMismatch",
    mismatch: EventsMismatch({expected: [evA], actual: [evB]}),
    format: "EventsMismatch:\n  expected: [{\n  \"TAG\": \"ProductAdded\",\n  \"_0\": {\n    \"productId\": \"p1\",\n    \"name\": \"Widget\"\n  }\n}]\n  actual:   [{\n  \"TAG\": \"ProductRenamed\",\n  \"_0\": {\n    \"productId\": \"p1\",\n    \"name\": \"Gadget\"\n  }\n}]",
    human: "  expected: [ProductAdded({productId: \"p1\", name: \"Widget\"})]\n  actual:   [ProductRenamed({productId: \"p1\", name: \"Gadget\"})]",
    tap: "  kind: \"EventsMismatch\"\n  expected: \"[ProductAdded({productId: \\\"p1\\\", name: \\\"Widget\\\"})]\"\n  actual: \"[ProductRenamed({productId: \\\"p1\\\", name: \\\"Gadget\\\"})]\"",
  },
  {
    name: "ErrorMismatch",
    mismatch: ErrorMismatch({
      expected: JSON.String("CategoryAlreadyExists"),
      actual: None,
      actualEvents: [evA],
    }),
    format: "ErrorMismatch:\n  expected error: \"CategoryAlreadyExists\"\n  actual error:   (none)\n  actual events:  [{\n  \"TAG\": \"ProductAdded\",\n  \"_0\": {\n    \"productId\": \"p1\",\n    \"name\": \"Widget\"\n  }\n}]",
    human: "  expected: Error(\"CategoryAlreadyExists\")\n  actual:   Ok([ProductAdded({productId: \"p1\", name: \"Widget\"})])",
    tap: "  kind: \"ErrorMismatch\"\n  expected: \"Error(\\\"CategoryAlreadyExists\\\")\"\n  actual: \"Ok([ProductAdded({productId: \\\"p1\\\", name: \\\"Widget\\\"})])\"",
  },
  {
    name: "StateMismatch",
    mismatch: StateMismatch({key: "p1", expected: Some(stateActive), actual: Some(stateArchived)}),
    format: "StateMismatch (key: p1):\n  expected: {\n  \"status\": \"active\"\n}\n  actual:   {\n  \"status\": \"archived\"\n}",
    human: "  key:      \"p1\"\n  expected: {status: \"active\"}\n  actual:   {status: \"archived\"}",
    tap: "  kind: \"StateMismatch\"\n  key: \"p1\"\n  expected: \"{status: \\\"active\\\"}\"\n  actual: \"{status: \\\"archived\\\"}\"",
  },
  {
    name: "NoEventExpected",
    mismatch: NoEventExpected({actual: [evA]}),
    format: "NoEventExpected: expected no events, got:\n  [{\n  \"TAG\": \"ProductAdded\",\n  \"_0\": {\n    \"productId\": \"p1\",\n    \"name\": \"Widget\"\n  }\n}]",
    human: "  expected no events\n  actual:   [ProductAdded({productId: \"p1\", name: \"Widget\"})]",
    tap: "  kind: \"NoEventExpected\"\n  actual: \"[ProductAdded({productId: \\\"p1\\\", name: \\\"Widget\\\"})]\"",
  },
  {
    name: "TranslateError",
    mismatch: TranslateError({expected: "boom", actual: Some("kaboom")}),
    format: "TranslateError:\n  expected: boom\n  actual:   kaboom",
    human: "  expected: boom\n  actual:   kaboom",
    tap: "  kind: \"TranslateError\"\n  expected: \"boom\"\n  actual: \"kaboom\"",
  },
  {
    name: "Throw",
    mismatch: Throw({error: "unexpected", stack: "at foo"}),
    format: "Throw: unexpected\nat foo",
    human: "  error: unexpected\nat foo",
    tap: "  kind: \"Throw\"\n  error: \"unexpected\"\n  stack: \"at foo\"",
  },
]

describe("Formatter golden outputs (per-mismatch rendering)", () => {
  goldens->Array.forEach(g => {
    testSync(`${g.name} — Outcome.format`, () => expect(Outcome.format(g.mismatch))->toEqual(g.format))
    testSync(`${g.name} — FormatterHuman.renderMismatch`, () =>
      expect(FormatterHuman.renderMismatch(g.mismatch))->toEqual(g.human)
    )
    testSync(`${g.name} — FormatterTap.renderMismatchYaml`, () =>
      expect(FormatterTap.renderMismatchYaml(g.mismatch))->toEqual(g.tap)
    )
  })
})
