open JestGlobals

// The words the bake function answers with and a connection config carries,
// held as variants: each reads back as its case and prints as the same word.

describe("BakeRegistrationState", () => {
  let words = ["registered", "unchanged", "matched", "missing", "behind", "diverged"]

  testSync("prints each state as the bake function answers it", () =>
    expect(BakeRegistrationState.all->Array.map(BakeRegistrationState.name))->toEqual(words)
  )

  testSync("the deploy script reads each word back, and keeps one it does not know", () =>
    expect(
      Array.concat(words, ["stalled"])->Array.map(
        w => BakeManifest.reportedStateOf(w)->BakeManifest.reportedStateText,
      ),
    )->toEqual(Array.concat(words, ["stalled"]))
  )
})

describe("the Postgres lock strategy", () => {
  testSync("a connection config's name reads back as the strategy, and no other", () =>
    expect(
      ["AdvisoryLocks", "RowLocks", "advisory", ""]->Array.map(
        w =>
          ReventlessPostgres.DcbEventLogStorage_Postgres_Ops.lockStrategyOfName(w)->Option.map(
            s => (s :> string),
          ),
      ),
    )->toEqual([Some("AdvisoryLocks"), Some("RowLocks"), None, None])
  )
})
