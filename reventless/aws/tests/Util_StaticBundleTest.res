open JestGlobals

let makeFixture = (): string => {
  let base = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "static-bundle-"]))
  NodeFs.writeFileSync(NodePath.join([base, "index.html"]), "<html></html>")
  NodeFs.writeFileSync(NodePath.join([base, "app.js"]), "console.log('x')")
  NodeFs.writeFileSync(NodePath.join([base, "app.css"]), "body{color:red}")
  NodeFs.writeFileSync(NodePath.join([base, ".DS_Store"]), "ignored")
  let assets = NodePath.join([base, "assets"])
  NodeFs.mkdirSync(assets, {recursive: true})
  NodeFs.writeFileSync(NodePath.join([assets, "logo.svg"]), "<svg/>")
  NodeFs.writeFileSync(NodePath.join([assets, "favicon.ico"]), "ico")
  base
}

describe("Util_StaticBundle.contentTypeFor", () => {
  testSync("html", () =>
    expect(Util_StaticBundle.contentTypeFor("index.html"))->toBe("text/html; charset=utf-8")
  )
  testSync("css", () =>
    expect(Util_StaticBundle.contentTypeFor("foo/bar.css"))->toBe("text/css; charset=utf-8")
  )
  testSync("js", () =>
    expect(Util_StaticBundle.contentTypeFor("app.js"))->toBe(
      "application/javascript; charset=utf-8",
    )
  )
  testSync("mjs", () =>
    expect(Util_StaticBundle.contentTypeFor("module.mjs"))->toBe(
      "application/javascript; charset=utf-8",
    )
  )
  testSync("json", () =>
    expect(Util_StaticBundle.contentTypeFor("data.json"))->toBe(
      "application/json; charset=utf-8",
    )
  )
  testSync("svg", () =>
    expect(Util_StaticBundle.contentTypeFor("logo.svg"))->toBe("image/svg+xml")
  )
  testSync("woff2", () =>
    expect(Util_StaticBundle.contentTypeFor("font.woff2"))->toBe("font/woff2")
  )
  testSync("wasm", () =>
    expect(Util_StaticBundle.contentTypeFor("blob.wasm"))->toBe("application/wasm")
  )
  testSync("uppercase extension is normalised", () =>
    expect(Util_StaticBundle.contentTypeFor("LOGO.PNG"))->toBe("image/png")
  )
  testSync("unknown extension defaults to octet-stream", () =>
    expect(Util_StaticBundle.contentTypeFor("blob.xyz"))->toBe("application/octet-stream")
  )
})

describe("Util_StaticBundle.sanitizeName", () => {
  testSync("replaces slashes with dashes", () =>
    expect(Util_StaticBundle.sanitizeName("foo/bar/baz"))->toBe("foo-bar-baz")
  )
  testSync("replaces dots with dashes", () =>
    expect(Util_StaticBundle.sanitizeName("index.html"))->toBe("index-html")
  )
  testSync("replaces both", () =>
    expect(Util_StaticBundle.sanitizeName("assets/logo.svg"))->toBe("assets-logo-svg")
  )
})

describe("Util_StaticBundle.walk", () => {
  testSync("returns one entry per file, skips dotfiles, uses forward slashes", () => {
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
    NodeFs.rmSync(dir, {recursive: true, force: true})
  })

  testSync("computes a non-empty content hash for each entry", () => {
    let dir = makeFixture()
    let entries = Util_StaticBundle.walk(dir)
    entries->Array.forEach(e => expect(e.contentHash->String.length > 0)->toBe(true))
    NodeFs.rmSync(dir, {recursive: true, force: true})
  })

  testSync("identical contents produce identical hashes", () => {
    let dir = makeFixture()
    let entries = Util_StaticBundle.walk(dir)
    let indexEntry =
      entries->Array.find(e => e.relativePath == "index.html")->Option.getUnsafe
    let indexHash = indexEntry.contentHash
    let dir2 = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "static-bundle-"]))
    NodeFs.writeFileSync(NodePath.join([dir2, "index.html"]), "<html></html>")
    let entries2 = Util_StaticBundle.walk(dir2)
    let indexHash2 = (entries2->Array.getUnsafe(0)).contentHash
    expect(indexHash)->toBe(indexHash2)
    NodeFs.rmSync(dir, {recursive: true, force: true})
    NodeFs.rmSync(dir2, {recursive: true, force: true})
  })

  testSync("different contents produce different hashes", () => {
    let dirA = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "static-bundle-"]))
    NodeFs.writeFileSync(NodePath.join([dirA, "f.txt"]), "AAA")
    let dirB = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "static-bundle-"]))
    NodeFs.writeFileSync(NodePath.join([dirB, "f.txt"]), "BBB")
    let hashA = (Util_StaticBundle.walk(dirA)->Array.getUnsafe(0)).contentHash
    let hashB = (Util_StaticBundle.walk(dirB)->Array.getUnsafe(0)).contentHash
    expect(hashA == hashB)->toBe(false)
    NodeFs.rmSync(dirA, {recursive: true, force: true})
    NodeFs.rmSync(dirB, {recursive: true, force: true})
  })

  testSync("throws when assetsDir does not exist", () => {
    let missing = NodePath.join([NodeOs.tmpdir(), "static-bundle-does-not-exist-xyz123"])
    let threw = try {
      let _ = Util_StaticBundle.walk(missing)
      false
    } catch {
    | _ => true
    }
    expect(threw)->toBe(true)
  })
})

describe("Util_StaticBundle.readJsonFileVerbatim", () => {
  let writeTmp = (contents: string): string => {
    let dir = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "ui-hints-"]))
    let path = NodePath.join([dir, "ui-hints.json"])
    NodeFs.writeFileSync(path, contents)
    path
  }

  testSync("returns the file's exact bytes for valid JSON (verbatim, not re-serialised)", () => {
    // Deliberately non-canonical formatting: extra spaces + trailing newline.
    let raw = "{\n  \"dashboards\":  [ ] \n}\n"
    let path = writeTmp(raw)
    expect(Util_StaticBundle.readJsonFileVerbatim(~path, ~label="test"))->toBe(raw)
    NodeFs.rmSync(path, {recursive: true, force: true})
  })

  testSync("throws on malformed JSON", () => {
    let path = writeTmp("{ not valid json ")
    let threw = try {
      let _ = Util_StaticBundle.readJsonFileVerbatim(~path, ~label="test")
      false
    } catch {
    | _ => true
    }
    expect(threw)->toBe(true)
    NodeFs.rmSync(path, {recursive: true, force: true})
  })

  testSync("throws when the file does not exist", () => {
    let missing = NodePath.join([NodeOs.tmpdir(), "ui-hints-missing-xyz123.json"])
    let threw = try {
      let _ = Util_StaticBundle.readJsonFileVerbatim(~path=missing, ~label="test")
      false
    } catch {
    | _ => true
    }
    expect(threw)->toBe(true)
  })
})
