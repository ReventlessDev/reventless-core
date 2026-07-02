// Unit tests for the watch re-run scope algebra (B1): a plain edit narrows the
// re-run to its owning test package, structural/add/full triggers widen to
// RunAll, and scopes coalesce (RunAll absorbing) while a pass is in flight.

open JestGlobals

describe("Cli.mergeScope", () => {
  testSync("RunAll absorbs on the left", () =>
    expect(Cli.mergeScope(RunAll, RunPackages(["/p/a"])))->toEqual(Cli.RunAll)
  )
  testSync("RunAll absorbs on the right", () =>
    expect(Cli.mergeScope(RunPackages(["/p/a"]), RunAll))->toEqual(Cli.RunAll)
  )
  testSync("two RunPackages union their dirs, deduplicated", () =>
    expect(Cli.mergeScope(RunPackages(["/p/a", "/p/b"]), RunPackages(["/p/b", "/p/c"])))->toEqual(
      Cli.RunPackages(["/p/a", "/p/b", "/p/c"]),
    )
  )
  testSync("RunAll merged with RunAll stays RunAll", () =>
    expect(Cli.mergeScope(RunAll, RunAll))->toEqual(Cli.RunAll)
  )
})

describe("Cli.pathUnderDir", () => {
  testSync("a file inside the dir is under it", () =>
    expect(Cli.pathUnderDir("/p/pkgA/tests/FooGwt.res.mjs", "/p/pkgA"))->toEqual(true)
  )
  testSync("a sibling with a shared prefix is NOT under it", () =>
    // /p/pkgABC must not be treated as inside /p/pkgA — the trailing separator
    // guards against the bare-prefix false positive.
    expect(Cli.pathUnderDir("/p/pkgABC/tests/FooGwt.res.mjs", "/p/pkgA"))->toEqual(false)
  )
  testSync("an unrelated path is not under it", () =>
    expect(Cli.pathUnderDir("/p/pkgB/tests/BarGwt.res.mjs", "/p/pkgA"))->toEqual(false)
  )
  testSync("a trailing-slash dir still matches", () =>
    expect(Cli.pathUnderDir("/p/pkgA/tests/FooGwt.res.mjs", "/p/pkgA/"))->toEqual(true)
  )
})

describe("Cli.scopeSubset", () => {
  let all = [
    "/p/pkgA/tests/FooGwt.res.mjs",
    "/p/pkgA/tests/BarGwt.res.mjs",
    "/p/pkgB/tests/BazGwt.res.mjs",
  ]
  testSync("RunAll returns every path", () =>
    expect(Cli.scopeSubset(RunAll, all))->toEqual(all)
  )
  testSync("RunPackages keeps only files under the given dirs", () =>
    expect(Cli.scopeSubset(RunPackages(["/p/pkgA"]), all))->toEqual([
      "/p/pkgA/tests/FooGwt.res.mjs",
      "/p/pkgA/tests/BarGwt.res.mjs",
    ])
  )
  testSync("RunPackages over multiple dirs unions their files", () =>
    expect(Cli.scopeSubset(RunPackages(["/p/pkgA", "/p/pkgB"]), all))->toEqual(all)
  )
  testSync("RunPackages with no matching dir yields no files", () =>
    expect(Cli.scopeSubset(RunPackages(["/p/pkgZ"]), all))->toEqual([])
  )
})
