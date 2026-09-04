// How the log format is decided. The rule that matters: a runtime may declare
// what it is, because stdout being a pipe means "log collector" for a Lambda and
// "a person is reading this" for `dev:full` — and the TTY probe cannot tell them
// apart.

@@warning("-44")

open JestGlobals

let envKey = "REVENTLESS_LOG_FORMAT"

// The module caches its decision, so every case sets the world then reloads. The
// declared default is module-level too, hence the explicit restore.
let resolve = (~env: option<string>, ~declared: option<[#text | #json]>): string => {
  switch env {
  | Some(v) => NodeProcess.env->Dict.set(envKey, v)
  | None => NodeProcess.env->Dict.delete(envKey)
  }
  Reventless.AnsiStyle._default := None
  switch declared {
  | Some(d) => Reventless.AnsiStyle.setDefaultFormat(d)
  | None => Reventless.AnsiStyle.reload()
  }
  Reventless.AnsiStyle.isJsonSink() ? "json" : "text"
}

describe("AnsiStyle format resolution", () => {
  // Jest's stdout is not a TTY, so with nothing declared these exercise the
  // deployed-runtime path.
  testSync("a non-TTY sink with nothing declared stays JSON", () =>
    expect(resolve(~env=None, ~declared=None))->toEqual("json")
  )

  // The fix: `pnpm run serve:watch` and `dev:full` pipe the platform's stdout, so
  // the probe alone called them log collectors and emitted JSON at a human.
  testSync("a runtime that declares itself human-read wins over the pipe", () =>
    expect(resolve(~env=None, ~declared=Some(#text)))->toEqual("text")
  )

  testSync("a runtime may also declare JSON", () =>
    expect(resolve(~env=None, ~declared=Some(#json)))->toEqual("json")
  )

  // The escape hatch has to survive the declaration, or a developer who wants the
  // structured form back from a local platform cannot have it.
  testSync("an explicit REVENTLESS_LOG_FORMAT beats what the runtime declared", () => {
    expect(resolve(~env=Some("json"), ~declared=Some(#text)))->toEqual("json")
    expect(resolve(~env=Some("text"), ~declared=Some(#json)))->toEqual("text")
  })

  testSync("an unrecognised value falls through rather than deciding", () =>
    expect(resolve(~env=Some("yaml"), ~declared=Some(#text)))->toEqual("text")
  )
})

// Leave the file as the rest of the suite expects: text, so ANSI assertions hold.
NodeProcess.env->Dict.set(envKey, "text")
Reventless.AnsiStyle._default := None
Reventless.AnsiStyle.reload()
