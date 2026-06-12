// Unit test for FormatterVsCode.messagePayload — the failure payload the
// VS Code extension renders. Asserts the `kind` discriminator (the mismatch
// family) is present so a client can gate the apply-expected quick-fix.

open JestGlobals

let failingResult = (~mismatch): RunnerTypes.testResult => {
  id: "t1",
  name: "rejects when category already exists",
  describePath: [],
  status: RunnerTypes.Fail,
  durationMs: 1.0,
  location: None,
  slice: None,
  mismatch,
  skipReason: None,
}

describe("FormatterVsCode.messagePayload", () => {
  testPromise("includes the mismatch kind for an EventsMismatch", async () => {
    let m = FormatterVsCode.messagePayload(
      failingResult(~mismatch=Some(Outcome.EventsMismatch({expected: [], actual: []}))),
    )
    expect(m.kind)->toEqual(Some("EventsMismatch"))
  })

  testPromise("includes the mismatch kind for an ErrorMismatch", async () => {
    let m = FormatterVsCode.messagePayload(
      failingResult(
        ~mismatch=Some(
          Outcome.ErrorMismatch({
            expected: JSON.String("CategoryAlreadyExists"),
            actual: None,
            actualEvents: [],
          }),
        ),
      ),
    )
    expect(m.kind)->toEqual(Some("ErrorMismatch"))
  })
})
