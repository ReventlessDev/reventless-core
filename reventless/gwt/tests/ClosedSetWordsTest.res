open JestGlobals

// The words a mismatch and a to-do status print with, held as variants: each
// prints as the word a report already carries.

describe("Outcome.mismatchKind", () => {
  testSync("a mismatch's kind prints as its constructor's name", () =>
    expect(
      [
        Outcome.EventsMismatch({expected: [], actual: []}),
        NoEventExpected({actual: []}),
        TranslateError({expected: "", actual: None}),
        PartitionUnresolved({boundary: "", reasons: []}),
        Throw({error: "", stack: ""}),
      ]->Array.map(Outcome.kindName),
    )->toEqual([
      "EventsMismatch",
      "NoEventExpected",
      "TranslateError",
      "PartitionUnresolved",
      "Throw",
    ])
  )

  testSync("the rendered mismatch carries the same kind", () =>
    expect(
      (MismatchRender.normalize(
        Outcome.StateMismatch({key: "k", expected: None, actual: None}),
      ).kind :> string),
    )->toBe("StateMismatch")
  )
})

describe("OutboundTranslation_GWT.todoStatus", () => {
  testSync("prints each status as a mismatch shows it", () =>
    expect(
      [OutboundTranslation_GWT.Completed, Failed, Abandoned, Pending]->Array.map(
        s => (s :> string),
      ),
    )->toEqual(["#Completed", "#Failed", "#Abandoned", "#Pending"])
  )
})
