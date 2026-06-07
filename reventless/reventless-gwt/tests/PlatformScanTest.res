// Unit tests for PlatformScan.matchPlatform — the pure predicate deciding whether
// a package.json + presence of src/Main.res.mjs make a launchable reventless-local
// platform package, and which serve script to prefer (features plan Phase 9).

open AsyncTest
open AsyncTest.Expect

let pkgJson = (~deps=`{}`, ~scripts=`{}`) =>
  `{"name":"@app/platform-local","dependencies":${deps},"scripts":${scripts}}`

describe("PlatformScan.matchPlatform", () => {
  testPromise("matches when it depends on reventless-local and Main.res.mjs exists", async () => {
    let text = pkgJson(~deps=`{"@reventlessdev/reventless-local":"workspace:*"}`)
    switch PlatformScan.matchPlatform(~pkgJsonText=text, ~mainExists=true) {
    | Some((name, _)) => expect(name)->toEqual("@app/platform-local")
    | None => expect("None")->toEqual("Some")
    }
  })

  testPromise("no match when src/Main.res.mjs is absent", async () => {
    let text = pkgJson(~deps=`{"@reventlessdev/reventless-local":"workspace:*"}`)
    expect(PlatformScan.matchPlatform(~pkgJsonText=text, ~mainExists=false)->Option.isNone)->toBe(
      true,
    )
  })

  testPromise("no match without the reventless-local dependency", async () => {
    let text = pkgJson(~deps=`{"sury":"^11"}`)
    expect(PlatformScan.matchPlatform(~pkgJsonText=text, ~mainExists=true)->Option.isNone)->toBe(
      true,
    )
  })

  testPromise("prefers the serve:memory script over serve", async () => {
    let text = pkgJson(
      ~deps=`{"@reventlessdev/reventless-local":"workspace:*"}`,
      ~scripts=`{"serve":"tsx Main","serve:memory":"REVENTLESS_LOCAL_BACKEND=memory tsx Main"}`,
    )
    switch PlatformScan.matchPlatform(~pkgJsonText=text, ~mainExists=true) {
    | Some((_, serveScript)) => expect(serveScript)->toEqual(Some("serve:memory"))
    | None => expect("None")->toEqual("Some")
    }
  })

  testPromise("falls back to serve when serve:memory is absent", async () => {
    let text = pkgJson(
      ~deps=`{"@reventlessdev/reventless-local":"workspace:*"}`,
      ~scripts=`{"serve":"tsx Main"}`,
    )
    switch PlatformScan.matchPlatform(~pkgJsonText=text, ~mainExists=true) {
    | Some((_, serveScript)) => expect(serveScript)->toEqual(Some("serve"))
    | None => expect("None")->toEqual("Some")
    }
  })

  testPromise("matches via devDependencies too", async () => {
    let text = `{"name":"p","devDependencies":{"@reventlessdev/reventless-local":"*"}}`
    expect(PlatformScan.matchPlatform(~pkgJsonText=text, ~mainExists=true)->Option.isSome)->toBe(
      true,
    )
  })
})
