open JestGlobals

// The `ui-hints.json` the local platform serves. Two things are under test:
// which file wins (the declaration or the host-shell package's own dev-mode
// fallback), and the baseline that makes a second boot — and a *withdrawn*
// declaration — land where they should. Every failure here is quiet: hints are
// presentation, so the symptom is a menu that reads slightly wrong.

let _ = TestRunner.setup()

let shipped = `{"Catalog": {"views": {"Products": {"nav": {"label": "Shipped"}}}}}`
let declared = `{"Catalog": {"views": {"Products": {"nav": {"label": "Declared"}}}}}`

let tmpdir = prefix => NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), prefix]))

let distWithHints = () => {
  let dir = tmpdir("reventless-uihints-dist-")
  NodeFs.writeFileSync(NodePath.join([dir, "ui-hints.json"]), shipped)
  dir
}

let declaredFile = (contents: string) => {
  let path = NodePath.join([tmpdir("reventless-uihints-src-"), "ui-hints.json"])
  NodeFs.writeFileSync(path, contents)
  path
}

let served = (dir: string) => NodeFs.readFileSync(NodePath.join([dir, "ui-hints.json"]))
let baselinePath = (dir: string) => NodePath.join([dir, "ui-hints.base.json"])

let threw = (f: unit => unit): bool =>
  try {
    f()
    false
  } catch {
  | _ => true
  }

describe("UiHints.emit", () => {
  testSync("serves the declared file verbatim", () => {
    let dir = distWithHints()
    UiHints.emit(~uiHintsFile=Some(declaredFile(declared)), ~dir)
    expect(served(dir))->toEqual(declared)
  })

  // An undeclared platform has to be byte-identical to one built before this
  // module existed, or every shell repo demonstration breaks to fix a problem
  // it does not have.
  testSync("leaves a platform that declares nothing entirely alone", () => {
    let dir = distWithHints()
    UiHints.emit(~uiHintsFile=None, ~dir)
    expect(served(dir))->toEqual(shipped)
    expect(NodeFs.existsSync(baselinePath(dir)))->toBe(false)
  })

  // Boot 2 seeding its baseline from boot 1's output would freeze the first
  // declaration in as "shipped" and make the withdrawal below unreachable.
  testSync("starts every boot from the shipped file, not the last output", () => {
    let dir = distWithHints()
    UiHints.emit(~uiHintsFile=Some(declaredFile(declared)), ~dir)
    UiHints.emit(~uiHintsFile=Some(declaredFile(shipped)), ~dir)
    expect(NodeFs.readFileSync(baselinePath(dir)))->toEqual(shipped)
  })

  testSync("restores the shipped file once the declaration is withdrawn", () => {
    let dir = distWithHints()
    UiHints.emit(~uiHintsFile=Some(declaredFile(declared)), ~dir)
    UiHints.emit(~uiHintsFile=None, ~dir)
    expect(served(dir))->toEqual(shipped)
  })

  // All three failures below produce the same symptom if swallowed — hints that
  // quietly are not applied — so each has to be the boot's problem, not the
  // reader's.
  testSync("refuses a declaration naming a file that does not exist", () => {
    let dir = distWithHints()
    let missing = NodePath.join([tmpdir("reventless-uihints-src-"), "absent.json"])
    expect(threw(() => UiHints.emit(~uiHintsFile=Some(missing), ~dir)))->toBe(true)
  })

  testSync("refuses a declared file that is not JSON", () => {
    let dir = distWithHints()
    expect(threw(() => UiHints.emit(~uiHintsFile=Some(declaredFile("not json")), ~dir)))->toBe(true)
  })

  // Read before anything is touched: a bad declaration must not leave the
  // served file half-replaced, which would be worse than either outcome.
  testSync("leaves the served file untouched when the declaration is bad", () => {
    let dir = distWithHints()
    let _ = threw(() => UiHints.emit(~uiHintsFile=Some(declaredFile("not json")), ~dir))
    expect(served(dir))->toEqual(shipped)
    expect(NodeFs.existsSync(baselinePath(dir)))->toBe(false)
  })
})
