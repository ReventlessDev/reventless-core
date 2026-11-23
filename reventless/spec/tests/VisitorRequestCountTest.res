open JestGlobals

// The ids a reader asks for: the minutes of the first hour from the minute
// something began, then every hour after. The UI computes the same ids, so these
// literals are the contract between the two.

// Named bare, as a module of this package: through `Reventless.` (an alias) the build
// records no dependency, and a fresh build compiles this test before the module.

let at = s => Date.fromString(s)

describe("VisitorRequestCount", () => {
  testSync("names a bucket by kind, length and start in seconds", () =>
    expect(VisitorRequestCount.idOf(~kind="door", ~seconds=60, ~start=1795431360.))->toBe(
      "door/60/1795431360",
    )
  )

  testSync("counts a request in its minute, its hour, and the row of every request", () =>
    expect((
      VisitorRequestCount.bucketsAt(at("2026-11-23T10:56:30Z")),
      VisitorRequestCount.everId(~kind="view"),
    ))->toEqual(([(60, 1795431360.), (3600, 1795428000.), (0, 0.)], "view/0/0"))
  )

  testSync("within one hour, asks for each minute from the first to now's", () =>
    expect(
      VisitorRequestCount.idsSince(
        ~kind="view",
        ~since=at("2026-11-23T10:56:30Z"),
        ~now=at("2026-11-23T10:58:10Z"),
      ),
    )->toEqual(["view/60/1795431360", "view/60/1795431420", "view/60/1795431480"])
  )

  testSync("past the first hour, its remaining minutes and then each hour to now's", () =>
    expect(
      VisitorRequestCount.idsSince(
        ~kind="door",
        ~since=at("2026-11-23T10:58:00Z"),
        ~now=at("2026-11-23T12:05:00Z"),
      ),
    )->toEqual([
      "door/60/1795431480",
      "door/60/1795431540",
      "door/3600/1795431600",
      "door/3600/1795435200",
    ])
  )

  testSync("asks for nothing when the start is after now", () =>
    expect(
      VisitorRequestCount.idsSince(
        ~kind="door",
        ~since=at("2026-11-23T11:00:00Z"),
        ~now=at("2026-11-23T10:00:00Z"),
      ),
    )->toEqual([])
  )

  testSync("keeps minutes for a week, hours for forty days, and every request for good", () =>
    expect((
      VisitorRequestCount.keptSeconds(VisitorRequestCount.minute),
      VisitorRequestCount.keptSeconds(VisitorRequestCount.hour),
      VisitorRequestCount.keptSeconds(VisitorRequestCount.ever),
    ))->toEqual((Some(691_200), Some(3_456_000), None))
  )
})
