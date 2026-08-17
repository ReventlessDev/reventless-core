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

// The dev loop: the platform follows the declared file so editing hints is a
// browser refresh rather than a restart. Real `fs.watch` events rather than a
// stubbed clock, because what is being tested IS the plumbing — a debounce over
// a fake timer would pass with the watcher wired to nothing.
//
// The rule these turn on is the one place `watch` parts company with `emit`: at
// boot a bad file is the deployment's mistake and taking the process down is the
// point, while mid-session it is almost always an editor mid-save, and killing a
// running dev server over a keystroke is worse than the restart this replaces.

// The edit is repeated, and that is not belt-and-braces.
//
// `fs.watch` does not promise that a write landing near the watcher's creation
// is reported. The FSEvents stream behind it on macOS is armed asynchronously,
// and a write that gets there first is not reported late — it is not reported at
// all. Measured against this very module: once the stream is up the edit is seen
// in about 10ms, and when it is not, the same edit produces no event in four
// seconds, with which of the two happens varying by how many watchers the
// process has already opened rather than by anything the test does.
//
// So a single edit tests the arming, not the reload. Repeating it on an interval
// far longer than a reload takes — 50ms of debounce plus a file copy — leaves the
// case where the first write lands identical to what it always was, and lets the
// case where it is dropped recover on the next one instead of reporting that hot
// reload is broken. Re-writing the same bytes is what a developer saving twice
// does, so nothing here asserts less than it did.
let retryEvery = 1000

// All three exits close the watcher AND clear both timers. A watcher is `unref`ed
// and would not hold the run open on its own, but a live 4-second timer would —
// and "Jest did not exit" on a suite that passed is exactly the noise that
// teaches a reader to ignore it.
let waitForReload = (~timeoutMs: int=4000, ~edit: unit => unit, ~uiHintsFile, ~dir) =>
  Promise.make((resolve, _) => {
    let fired = ref(0)
    let watcher = ref(None)
    let deadline = ref(None)
    let retry = ref(None)
    // Resolves with a count rather than rejecting on the deadline: "nothing was
    // re-served" is the expected answer in half these cases, and a rejection
    // would make the assertion read as an infrastructure failure.
    let finish = () => {
      watcher.contents->Option.forEach(NodeFs.watcherClose)
      deadline.contents->Option.forEach(clearTimeout)
      retry.contents->Option.forEach(clearTimeout)
      resolve(fired.contents)
    }
    let rec editUntilSeen = () => {
      edit()
      retry := Some(setTimeout(editUntilSeen, retryEvery))
    }
    watcher :=
      UiHints.watch(~uiHintsFile, ~dir, ~onReload=() => {
        fired := fired.contents + 1
        finish()
      })
    deadline := Some(setTimeout(finish, timeoutMs))
    editUntilSeen()
  })

describe("UiHints.watch", () => {
  testSync("watches nothing when the platform declares no hints file", () =>
    expect(UiHints.watch(~uiHintsFile=None, ~onReload=() => ()))->toEqual(None)
  )

  testSync("declines to watch a path whose directory is gone, without throwing", () => {
    let missing = NodePath.join([tmpdir("reventless-uihints-gone-"), "nowhere", "ui-hints.json"])
    expect(UiHints.watch(~uiHintsFile=Some(missing), ~onReload=() => ()))->toEqual(None)
  })

  test("re-serves the file when it changes, and says so", async () => {
    let dir = distWithHints()
    let path = declaredFile(declared)
    UiHints.emit(~uiHintsFile=Some(path), ~dir)
    let edited = `{"Catalog": {"views": {"Products": {"nav": {"label": "Edited"}}}}}`
    let fired = await waitForReload(
      ~uiHintsFile=Some(path),
      ~dir,
      ~edit=() => NodeFs.writeFileSync(path, edited),
    )
    expect((fired > 0, served(dir)))->toEqual((true, edited))
  })

  // The save that arrives in two writes. Serving the truncated middle would put
  // a file the shell cannot parse in front of every caller; throwing would end
  // the session over a keystroke. Neither: the previous copy stands.
  test("keeps serving the last good copy when the file is momentarily not JSON", async () => {
    let dir = distWithHints()
    let path = declaredFile(declared)
    UiHints.emit(~uiHintsFile=Some(path), ~dir)
    let fired = await waitForReload(
      ~timeoutMs=1500,
      ~uiHintsFile=Some(path),
      ~dir,
      ~edit=() => NodeFs.writeFileSync(path, `{"Catalog": {"views":`),
    )
    expect((fired, served(dir)))->toEqual((0, declared))
  })

  // …and the save completing is itself the next event, so recovery needs no
  // second trigger. This is why a failed reload can be silent about retrying.
  test("recovers on the write that finishes the save", async () => {
    let dir = distWithHints()
    let path = declaredFile(declared)
    UiHints.emit(~uiHintsFile=Some(path), ~dir)
    let whole = `{"Catalog": {"views": {"Products": {"nav": {"label": "Whole"}}}}}`
    let fired = await waitForReload(
      ~uiHintsFile=Some(path),
      ~dir,
      // Both halves of the save, so a repeat of this edit is the same story told
      // again and still ends on the whole file — never a truncated write left
      // standing after a complete one.
      ~edit=() => {
        NodeFs.writeFileSync(path, `{"Catalog": {"views":`)
        let _ = setTimeout(() => NodeFs.writeFileSync(path, whole), 200)
      },
    )
    expect((fired > 0, served(dir)))->toEqual((true, whole))
  })
})
