// SIGINT / SIGTERM trap. Sets a module-level flag that the main loop
// polls between tests. The VS Code and JSON streaming formatters flush a
// `runEnd` event with the skipped remainder before the process exits.

type process
@val external process: process = "process"
@send external onSignal: (process, string, unit => unit) => unit = "on"
@send external exit: (process, int) => unit = "exit"

let cancelled = ref(false)
let handlers: ref<array<unit => unit>> = ref([])

let isCancelled = () => cancelled.contents

let onCancel = (handler: unit => unit) =>
  handlers := Array.concat(handlers.contents, [handler])

let install = () => {
  let handler = () => {
    if !cancelled.contents {
      cancelled := true
      handlers.contents->Array.forEach(h =>
        try h() catch {
        | _ => ()
        }
      )
    } else {
      // Second signal: the first requested a graceful drain, but a hung await
      // can keep the process alive indefinitely. Honour the operator's repeat
      // SIGINT/SIGTERM as a hard exit (130 = terminated by SIGINT) so only the
      // one signal — not SIGKILL — is needed to break out.
      process->exit(130)
    }
  }
  process->onSignal("SIGINT", handler)
  process->onSignal("SIGTERM", handler)
}
