// Unit test for FormatterVsCode.messagePayload — the failure payload the
// VS Code extension renders. Asserts the `kind` discriminator (the mismatch
// family) is present so a client can gate the apply-expected quick-fix.

open AsyncTest
open AsyncTest.Expect

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

let getField = (j: JSON.t, k: string): option<JSON.t> =>
  switch j {
  | Object(o) => o->Dict.get(k)
  | _ => None
  }

describe("FormatterVsCode.messagePayload", () => {
  testPromise("includes the mismatch kind for an EventsMismatch", async () => {
    let j = FormatterVsCode.messagePayload(
      failingResult(~mismatch=Some(Outcome.EventsMismatch({expected: [], actual: []}))),
    )
    expect(getField(j, "kind"))->toEqual(Some(JSON.String("EventsMismatch")))
  })

  testPromise("includes the mismatch kind for an ErrorMismatch", async () => {
    let j = FormatterVsCode.messagePayload(
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
    expect(getField(j, "kind"))->toEqual(Some(JSON.String("ErrorMismatch")))
  })
})
