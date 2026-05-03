open TestHelpers

@module("fs") external mkdtempSync: string => string = "mkdtempSync"
@module("fs") external mkdirSync: (string, {"recursive": bool}) => unit = "mkdirSync"
@module("fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("fs") external rmSync: (string, {"recursive": bool, "force": bool}) => unit = "rmSync"
@module("path") external join2: (string, string) => string = "join"
@module("os") external tmpdir: unit => string = "tmpdir"

let makeFixture = (): string => {
  let base = mkdtempSync(join2(tmpdir(), "static-bundle-"))
  writeFileSync(join2(base, "index.html"), "<html></html>")
  writeFileSync(join2(base, "app.js"), "console.log('x')")
  writeFileSync(join2(base, "app.css"), "body{color:red}")
  writeFileSync(join2(base, ".DS_Store"), "ignored")
  let assets = join2(base, "assets")
  mkdirSync(assets, {"recursive": true})
  writeFileSync(join2(assets, "logo.svg"), "<svg/>")
  writeFileSync(join2(assets, "favicon.ico"), "ico")
  base
}

describe("Util_StaticBundle.contentTypeFor", () => {
  test("html", () =>
    expect(Util_StaticBundle.contentTypeFor("index.html"))->toBe("text/html; charset=utf-8")
  )
  test("css", () =>
    expect(Util_StaticBundle.contentTypeFor("foo/bar.css"))->toBe("text/css; charset=utf-8")
  )
  test("js", () =>
    expect(Util_StaticBundle.contentTypeFor("app.js"))->toBe(
      "application/javascript; charset=utf-8",
    )
  )
  test("mjs", () =>
    expect(Util_StaticBundle.contentTypeFor("module.mjs"))->toBe(
      "application/javascript; charset=utf-8",
    )
  )
  test("json", () =>
    expect(Util_StaticBundle.contentTypeFor("data.json"))->toBe(
      "application/json; charset=utf-8",
    )
  )
  test("svg", () =>
    expect(Util_StaticBundle.contentTypeFor("logo.svg"))->toBe("image/svg+xml")
  )
  test("woff2", () =>
    expect(Util_StaticBundle.contentTypeFor("font.woff2"))->toBe("font/woff2")
  )
  test("wasm", () =>
    expect(Util_StaticBundle.contentTypeFor("blob.wasm"))->toBe("application/wasm")
  )
  test("uppercase extension is normalised", () =>
    expect(Util_StaticBundle.contentTypeFor("LOGO.PNG"))->toBe("image/png")
  )
  test("unknown extension defaults to octet-stream", () =>
    expect(Util_StaticBundle.contentTypeFor("blob.xyz"))->toBe("application/octet-stream")
  )
})

describe("Util_StaticBundle.sanitizeName", () => {
  test("replaces slashes with dashes", () =>
    expect(Util_StaticBundle.sanitizeName("foo/bar/baz"))->toBe("foo-bar-baz")
  )
  test("replaces dots with dashes", () =>
    expect(Util_StaticBundle.sanitizeName("index.html"))->toBe("index-html")
  )
  test("replaces both", () =>
    expect(Util_StaticBundle.sanitizeName("assets/logo.svg"))->toBe("assets-logo-svg")
  )
})

describe("Util_StaticBundle.walk", () => {
  test("returns one entry per file, skips dotfiles, uses forward slashes", () => {
    let dir = makeFixture()
    let entries = Util_StaticBundle.walk(dir)
    let keys =
      entries
      ->Array.map(e => e.relativePath)
      ->Array.toSorted(String.compare)
    expect(keys)->toEqual([
      "app.css",
      "app.js",
      "assets/favicon.ico",
      "assets/logo.svg",
      "index.html",
    ])
    rmSync(dir, {"recursive": true, "force": true})
  })

  test("computes a non-empty content hash for each entry", () => {
    let dir = makeFixture()
    let entries = Util_StaticBundle.walk(dir)
    entries->Array.forEach(e => expect(e.contentHash->String.length > 0)->toBe(true))
    rmSync(dir, {"recursive": true, "force": true})
  })

  test("identical contents produce identical hashes", () => {
    let dir = makeFixture()
    let entries = Util_StaticBundle.walk(dir)
    let indexEntry =
      entries->Array.find(e => e.relativePath == "index.html")->Option.getUnsafe
    let indexHash = indexEntry.contentHash
    let dir2 = mkdtempSync(join2(tmpdir(), "static-bundle-"))
    writeFileSync(join2(dir2, "index.html"), "<html></html>")
    let entries2 = Util_StaticBundle.walk(dir2)
    let indexHash2 = (entries2->Array.getUnsafe(0)).contentHash
    expect(indexHash)->toBe(indexHash2)
    rmSync(dir, {"recursive": true, "force": true})
    rmSync(dir2, {"recursive": true, "force": true})
  })

  test("different contents produce different hashes", () => {
    let dirA = mkdtempSync(join2(tmpdir(), "static-bundle-"))
    writeFileSync(join2(dirA, "f.txt"), "AAA")
    let dirB = mkdtempSync(join2(tmpdir(), "static-bundle-"))
    writeFileSync(join2(dirB, "f.txt"), "BBB")
    let hashA = (Util_StaticBundle.walk(dirA)->Array.getUnsafe(0)).contentHash
    let hashB = (Util_StaticBundle.walk(dirB)->Array.getUnsafe(0)).contentHash
    expect(hashA == hashB)->toBe(false)
    rmSync(dirA, {"recursive": true, "force": true})
    rmSync(dirB, {"recursive": true, "force": true})
  })

  test("throws when assetsDir does not exist", () => {
    let missing = join2(tmpdir(), "static-bundle-does-not-exist-xyz123")
    let threw = try {
      let _ = Util_StaticBundle.walk(missing)
      false
    } catch {
    | _ => true
    }
    expect(threw)->toBe(true)
  })
})
