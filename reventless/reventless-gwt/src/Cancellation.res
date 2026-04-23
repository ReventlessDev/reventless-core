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
    }
  }
  process->onSignal("SIGINT", handler)
  process->onSignal("SIGTERM", handler)
}
