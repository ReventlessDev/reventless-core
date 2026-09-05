open JestGlobals

// The `ui-slots.js` the local platform serves. Two things are under test: that a
// declared module reaches the served dist/ unaltered, and that an undeclared
// platform serves *nothing* — which is where this parts company with the hints
// file, whose "nothing" means the host-shell package's own fallback.
//
// Every failure here is quiet in the worst way. Hints going unapplied read as a
// menu that is slightly wrong; renderers going unapplied read as a surface that
// was never customised, which is indistinguishable from one nobody customised.

let _ = TestRunner.setup()

// The shape the shell actually calls (`SlotModules.load`): one `register`
// export, handed `h` and the registry. Nothing here evaluates it — the bytes are
// what is under test — but a fixture that misstated the contract would be read
// as documentation of it.
let declared = `export function register({ h, slots }) {
  slots.row("gallery.tile", ({ row }) => h("span", null, row.name))
}
`
let edited = `export function register({ h, slots }) {
  slots.row("gallery.tile", ({ row }) => h("strong", null, row.name))
}
`

let tmpdir = prefix => NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), prefix]))

// No shipped counterpart, deliberately: the shell ships no slots module, and a
// fixture that invented one would test a fallback this seam must not have.
let emptyDist = () => tmpdir("reventless-uislots-dist-")

let declaredFile = (contents: string) => {
  let path = NodePath.join([tmpdir("reventless-uislots-src-"), "storefront-slots.js"])
  NodeFs.writeFileSync(path, contents)
  path
}

let servedPath = (dir: string) => NodePath.join([dir, "ui-slots.js"])
let served = (dir: string) => NodeFs.readFileSync(servedPath(dir))
let isServed = (dir: string) => NodeFs.existsSync(servedPath(dir))

let threw = (f: unit => unit): bool =>
  try {
    f()
    false
  } catch {
  | _ => true
  }

describe("UiSlots.emit", () => {
  testSync("serves the declared module verbatim", () => {
    let dir = emptyDist()
    UiSlots.emit(~uiSlotsFile=Some(declaredFile(declared)), ~dir)
    expect(served(dir))->toEqual(declared)
  })

  // An undeclared platform has to be byte-identical to one built before this
  // module existed.
  testSync("writes nothing when the platform declares no slots file", () => {
    let dir = emptyDist()
    UiSlots.emit(~uiSlotsFile=None, ~dir)
    expect(isServed(dir))->toBe(false)
  })

  // The counterpart to the hints baseline. There is no file to restore, so the
  // state to return to is "no file" — leaving yesterday's renderers in place
  // with nothing in the deployment to explain them is the failure a baseline
  // exists to prevent, arriving by the other road.
  testSync("removes the served module once the declaration is withdrawn", () => {
    let dir = emptyDist()
    UiSlots.emit(~uiSlotsFile=Some(declaredFile(declared)), ~dir)
    UiSlots.emit(~uiSlotsFile=None, ~dir)
    expect(isServed(dir))->toBe(false)
  })

  testSync("withdrawing twice is not an error", () => {
    let dir = emptyDist()
    UiSlots.emit(~uiSlotsFile=None, ~dir)
    expect(threw(() => UiSlots.emit(~uiSlotsFile=None, ~dir)))->toBe(false)
  })

  // The one failure this side can see, and it has to be the boot's problem: a
  // declaration pointing nowhere registers no renderers and says nothing about
  // why, which reads as a seam that does not work.
  testSync("refuses a declaration naming a file that does not exist", () => {
    let dir = emptyDist()
    let missing = NodePath.join([tmpdir("reventless-uislots-src-"), "absent.js"])
    expect(threw(() => UiSlots.emit(~uiSlotsFile=Some(missing), ~dir)))->toBe(true)
  })

  // Read before anything is touched: a bad declaration must not leave the served
  // module half-replaced, which would be worse than either outcome.
  testSync("leaves the last good module in place when the declaration is bad", () => {
    let dir = emptyDist()
    UiSlots.emit(~uiSlotsFile=Some(declaredFile(declared)), ~dir)
    let missing = NodePath.join([tmpdir("reventless-uislots-src-"), "absent.js"])
    let _ = threw(() => UiSlots.emit(~uiSlotsFile=Some(missing), ~dir))
    expect(served(dir))->toEqual(declared)
  })

  // The deliberate non-check. There is no cheap way to know a module is good
  // short of evaluating it, the deploy half cannot do it either, and a check
  // that only ran locally would let a file pass the loop it was authored in and
  // fail the one it ships to. The shell reports what it could not import.
  testSync("serves a module it cannot vouch for rather than refusing it", () => {
    let dir = emptyDist()
    let broken = "export const register = (r) => {"
    UiSlots.emit(~uiSlotsFile=Some(declaredFile(broken)), ~dir)
    expect(served(dir))->toEqual(broken)
  })
})

// The dev loop. Real `fs.watch` events rather than a stubbed clock, because what
// is being tested IS the plumbing — a debounce over a fake timer would pass with
// the watcher wired to nothing.
//
// The repeated edit is not belt-and-braces: `fs.watch` does not promise that a
// write landing near the watcher's creation is reported, and on macOS a write
// that beats the FSEvents stream up is not reported late but not at all. See the
// long note in `UiHintsTest` — the same reasoning and the same interval.
let retryEvery = 1000

let waitForReload = (~timeoutMs: int=4000, ~edit: unit => unit, ~uiSlotsFile, ~dir) =>
  Promise.make((resolve, _) => {
    let fired = ref(0)
    let watcher = ref(None)
    let deadline = ref(None)
    let retry = ref(None)
    // Resolves with a count rather than rejecting on the deadline: "nothing was
    // re-served" is an expected answer here, and a rejection would make the
    // assertion read as an infrastructure failure.
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
      UiSlots.watch(~uiSlotsFile, ~dir, ~onReload=() => {
        fired := fired.contents + 1
        finish()
      })
    deadline := Some(setTimeout(finish, timeoutMs))
    editUntilSeen()
  })

describe("UiSlots.watch", () => {
  testSync("watches nothing when the platform declares no slots file", () =>
    expect(UiSlots.watch(~uiSlotsFile=None, ~onReload=() => ()))->toEqual(None)
  )

  testSync("declines to watch a path whose directory is gone, without throwing", () => {
    let missing = NodePath.join([tmpdir("reventless-uislots-gone-"), "nowhere", "slots.js"])
    expect(UiSlots.watch(~uiSlotsFile=Some(missing), ~onReload=() => ()))->toEqual(None)
  })

  test("re-serves the module when it changes, and says so", async () => {
    let dir = emptyDist()
    let path = declaredFile(declared)
    UiSlots.emit(~uiSlotsFile=Some(path), ~dir)
    let fired = await waitForReload(
      ~uiSlotsFile=Some(path),
      ~dir,
      ~edit=() => NodeFs.writeFileSync(path, edited),
    )
    expect((fired > 0, served(dir)))->toEqual((true, edited))
  })

  // Mid-session the file going unreadable is almost always an editor between two
  // writes, and killing a running dev server over a keystroke would make this
  // worse than the restart it replaces. The previous copy stands, and the save
  // completing is itself the next event, so recovery needs no second trigger.
  test("keeps serving the last good copy when the file is momentarily unreadable", async () => {
    let dir = emptyDist()
    let path = declaredFile(declared)
    UiSlots.emit(~uiSlotsFile=Some(path), ~dir)
    let fired = await waitForReload(
      ~timeoutMs=1500,
      ~uiSlotsFile=Some(path),
      ~dir,
      // Write-then-unlink rather than a bare unlink, so the edit stays repeatable
      // for the retry above: it raises events every time and lands in the same
      // absent state each time. It is also what a rename-based editor save
      // actually does — the window this is about is the one between the two.
      ~edit=() => {
        NodeFs.writeFileSync(path, edited)
        NodeFs.unlinkSync(path)
      },
    )
    expect((fired, served(dir)))->toEqual((0, declared))
  })
})
