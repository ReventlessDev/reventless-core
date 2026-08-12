open JestGlobals

// This file asserts on EMITTED log output, so it pins the level it needs rather
// than inheriting whatever the runner exported — `LOG_LEVEL=silent` would
// suppress the warning and turn every case below green for the wrong reason.
// `Logger` re-reads process.env on each call, so a file-scope assignment holds.
NodeProcess.env->Dict.set("LOG_LEVEL", "warn")

type consoleObj = {mutable log: string => unit}
@val external console: consoleObj = "console"

let capture = (fn: unit => unit): array<string> => {
  let lines: array<string> = []
  let original = console.log
  console.log = s => lines->Array.push(s)
  let result = try {
    fn()
    Ok()
  } catch {
  | e => Error(e)
  }
  console.log = original
  switch result {
  | Ok() => lines
  | Error(e) => throw(e)
  }
}

let warnFor = (~view, ~ownerField, ~elevated) => {
  OwnerScopeDiagnostics.resetWarnings()
  Reventless.OwnerScope.setElevatedGroups(elevated)
  let lines = capture(() =>
    OwnerScopeDiagnostics.warnIfNoElevatedGroups(~comp="Test", ~view, ~ownerField)
  )
  Reventless.OwnerScope.setElevatedGroups([])
  lines
}

describe("OwnerScopeDiagnostics:", () => {
  testSync("an owner-scoped view with no elevated groups warns", () =>
    expect(warnFor(~view="Orders", ~ownerField=Some("customerId"), ~elevated=[])->Array.length)->toBe(
      1,
    )
  )

  // The consequence is the whole point of the line — an operator reading
  // "configure elevated groups" without being told that admins are currently
  // scoped has no reason to treat it as urgent.
  testSync("the warning names the view, the field, and what will happen", () => {
    let line =
      warnFor(~view="Orders", ~ownerField=Some("customerId"), ~elevated=[])
      ->Array.get(0)
      ->Option.getOr("")
    expect((
      line->String.includes("Orders"),
      line->String.includes("customerId"),
      line->String.includes("only their own rows"),
    ))->toEqual((true, true, true))
  })

  testSync("a view with no owner field is silent", () =>
    expect(warnFor(~view="Products", ~ownerField=None, ~elevated=[])->Array.length)->toBe(0)
  )

  testSync("a configured deployment is silent", () =>
    expect(
      warnFor(~view="Orders", ~ownerField=Some("customerId"), ~elevated=["Admin"])->Array.length,
    )->toBe(0)
  )

  // Registration runs more than once per process — tests build several
  // platforms, a deploy walks every plugin. A line repeated per construction is
  // one people learn to scroll past.
  testSync("the same view warns once, not once per registration", () => {
    OwnerScopeDiagnostics.resetWarnings()
    Reventless.OwnerScope.setElevatedGroups([])
    let lines = capture(() => {
      OwnerScopeDiagnostics.warnIfNoElevatedGroups(
        ~comp="Test",
        ~view="Orders",
        ~ownerField=Some("customerId"),
      )
      OwnerScopeDiagnostics.warnIfNoElevatedGroups(
        ~comp="Test",
        ~view="Orders",
        ~ownerField=Some("customerId"),
      )
    })
    expect(lines->Array.length)->toBe(1)
  })

  testSync("a second view gets its own warning", () => {
    OwnerScopeDiagnostics.resetWarnings()
    Reventless.OwnerScope.setElevatedGroups([])
    let lines = capture(() => {
      OwnerScopeDiagnostics.warnIfNoElevatedGroups(
        ~comp="Test",
        ~view="Orders",
        ~ownerField=Some("customerId"),
      )
      OwnerScopeDiagnostics.warnIfNoElevatedGroups(
        ~comp="Test",
        ~view="Invoices",
        ~ownerField=Some("payerId"),
      )
    })
    expect(lines->Array.length)->toBe(2)
  })
})
