open JestGlobals

// The `sign-in-notice.json` the local platform serves for the sign-in page: the
// copy it serves from the working directory's source, the removal when the
// source goes, and the watch that follows a source written after the start.

let _ = TestRunner.setup()

let tmpdir = prefix => NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), prefix]))

// A working directory's `.reventless` folder, empty; the source is not there yet.
let sourceIn = () => NodePath.join([tmpdir("reventless-notice-src-"), SignInNotice.fileName])

let servedPath = (dir: string) => NodePath.join([dir, SignInNotice.fileName])
let served = (dir: string) => NodeFs.readFileSync(servedPath(dir))

let notice = text =>
  JSON.stringify(Dict.fromArray([("text", JSON.Encode.string(text))])->JSON.Encode.object)

describe("SignInNotice.emit", () => {
  testSync("serves the text of the source", () => {
    let dir = tmpdir("reventless-notice-dist-")
    let source = sourceIn()
    NodeFs.writeFileSync(source, `{"text": "Nobody can sign in to this app yet.", "other": 1}`)
    expect(SignInNotice.emit(~source, ~dir))->toEqual(Ok())
    expect(served(dir))->toEqual(notice("Nobody can sign in to this app yet."))
  })

  testSync("serves nothing, and removes what it served, when the source is absent", () => {
    let dir = tmpdir("reventless-notice-dist-")
    let source = sourceIn()
    NodeFs.writeFileSync(source, notice("Before"))
    let _ = SignInNotice.emit(~source, ~dir)
    NodeFs.unlinkSync(source)
    expect(SignInNotice.emit(~source, ~dir))->toEqual(Ok())
    expect(NodeFs.existsSync(servedPath(dir)))->toBe(false)
  })

  testSync("keeps the served copy when the source is not a notice", () => {
    let dir = tmpdir("reventless-notice-dist-")
    let source = sourceIn()
    NodeFs.writeFileSync(source, notice("Good"))
    let _ = SignInNotice.emit(~source, ~dir)
    let refused = [`{"text": `, `{"note": "x"}`, `["text"]`]->Array.map(
      contents => {
        NodeFs.writeFileSync(source, contents)
        SignInNotice.emit(~source, ~dir)->Result.isError
      },
    )
    expect((refused, served(dir)))->toEqual(([true, true, true], notice("Good")))
  })
})

// Real `fs.watch` events, with the edit repeated for the reason `UiHintsTest`
// gives: a write that lands before the watch is armed is not reported at all.
let waitForReload = (~timeoutMs: int=4000, ~edit: unit => unit, ~source, ~dir) =>
  Promise.make((resolve, _) => {
    let fired = ref(0)
    let watcher = ref(None)
    let deadline = ref(None)
    let retry = ref(None)
    let finish = () => {
      watcher.contents->Option.forEach(NodeFs.watcherClose)
      deadline.contents->Option.forEach(clearTimeout)
      retry.contents->Option.forEach(clearTimeout)
      resolve(fired.contents)
    }
    let rec editUntilSeen = () => {
      edit()
      retry := Some(setTimeout(editUntilSeen, 1000))
    }
    watcher :=
      SignInNotice.watch(~source, ~dir, ~onReload=() => {
        fired := fired.contents + 1
        finish()
      })
    deadline := Some(setTimeout(finish, timeoutMs))
    editUntilSeen()
  })

describe("SignInNotice.watch", () => {
  testSync("declines to watch where the source's folder does not exist", () => {
    let missing = NodePath.join([
      tmpdir("reventless-notice-gone-"),
      "nowhere",
      "sign-in-notice.json",
    ])
    expect(SignInNotice.watch(~source=missing, ~onReload=() => ()))->toEqual(None)
  })

  test("serves a source written after the watch started, and says so", async () => {
    let dir = tmpdir("reventless-notice-dist-")
    let source = sourceIn()
    let _ = SignInNotice.emit(~source, ~dir)
    let text = "Sign in as emil (Operations) or ada (Driver)."
    let fired = await waitForReload(
      ~source,
      ~dir,
      ~edit=() => NodeFs.writeFileSync(source, notice(text)),
    )
    expect((fired > 0, served(dir)))->toEqual((true, notice(text)))
  })

  test("re-serves a changed source", async () => {
    let dir = tmpdir("reventless-notice-dist-")
    let source = sourceIn()
    NodeFs.writeFileSync(source, notice("Nobody can sign in to this app yet."))
    let _ = SignInNotice.emit(~source, ~dir)
    let fired = await waitForReload(
      ~source,
      ~dir,
      ~edit=() => NodeFs.writeFileSync(source, notice("Sign in as emil.")),
    )
    expect((fired > 0, served(dir)))->toEqual((true, notice("Sign in as emil.")))
  })
})

describe("SignInNotice on the events channel", () => {
  beforeEach(() => LocalEvents_Server.resetConnections())

  testSync("a page subscribed to the notice channel is told it changed", () => {
    let frames = []
    let conn = LocalEvents_Server.addConnection(~send=f => frames->Array.push(f))
    conn.subscriptions->Dict.set("s1", LocalEvents_Server.devSignInNoticeChannel)
    LocalEvents_Server.broadcastSignInNoticeChanged()
    let kinds = frames->Array.filterMap(
      f =>
        f
        ->JSON.parseOrThrow
        ->JSON.Decode.object
        ->Option.flatMap(o => o->Dict.get("event"))
        ->Option.flatMap(JSON.Decode.string),
    )
    expect(kinds->Array.some(e => e->String.includes("signInNoticeChanged")))->toBe(true)
  })
})
