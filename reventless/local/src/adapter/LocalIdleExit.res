// A platform started for an editor, and left running across the editor's reload, stops on its
// own once nothing has watched it for a while: `REVENTLESS_IDLE_EXIT=<seconds>` turns it on.
// Watching is a connection to the log feed or the event tap, which an editor holds while it is
// open; a reload reconnects within seconds, quitting the editor never does. The platform then
// stops the way a SIGTERM stops it, its registry entry removed on the way out.

let log = ReventlessCore.Logger.fromEnv()

let envVar = "REVENTLESS_IDLE_EXIT"

/** The idle time allowed, in milliseconds; none when the variable is unset, empty or not a
    positive number. */
let graceOf = (value: option<string>): option<int> =>
  value
  ->Option.flatMap(v => Int.fromString(v->String.trim))
  ->Option.flatMap(s => s > 0 ? Some(s * 1000) : None)

let grace: ref<option<int>> = ref(None)
let watchers = ref(0)
let timer: ref<option<timeoutId>> = ref(None)

/** What happens when the time runs out; replaced by tests. */
let onIdle: ref<unit => unit> = ref(() => NodeProcess.killWithSignal(NodeProcess.pid, "SIGTERM"))

let disarm = () => {
  timer.contents->Option.forEach(clearTimeout)
  timer := None
}

let arm = () =>
  grace.contents->Option.forEach(ms => {
    disarm()
    timer := Some(setTimeout(() => {
          timer := None
          log.info(
            ~comp="Platform",
            `nothing watched this platform for ${(ms / 1000)->Int.toString} s — stopping`,
          )
          onIdle.contents()
        }, ms))
  })

/** Starts counting idle time, when the environment asks for it: from now until the first
    watcher connects. */
let start = (~env: dict<string>) => {
  grace := graceOf(env->Dict.get(envVar))
  if watchers.contents == 0 {
    arm()
  }
}

/** A watcher connected: the platform is watched again. */
let connected = () => {
  watchers := watchers.contents + 1
  disarm()
}

/** A watcher went away; the last one leaving starts the idle time. */
let disconnected = () => {
  watchers := Math.Int.max(0, watchers.contents - 1)
  if watchers.contents == 0 {
    arm()
  }
}

/** Back to nothing counted: for tests. */
let reset = () => {
  disarm()
  grace := None
  watchers := 0
}
