// One shared readline interface for every interactive prompt in a seed run.
//
// The reason this module exists: creating and closing a fresh `readline`
// interface per prompt leaves NodeProcess.stdin paused after the first `close`, so the
// second prompt (password after username) never fires and the run hangs. A
// single interface, created lazily and closed exactly once, avoids that — and a
// `muted` gate on its output lets password entry reuse the same interface
// instead of opening a second one just to suppress the echo.
//
// Node bindings are declared here as typed externals; this package is
// stdlib-only, so no `%raw`.

open Seed_Types

// ── Node bindings ─────────────────────────────────────────────────────────────

type rl
type rlOptions = {input: NodeProcess.stream, output: NodeProcess.stream, terminal?: bool}
@module("node:readline") external createInterface: rlOptions => rl = "createInterface"
@send external question: (rl, string, string => unit) => unit = "question"
@send external closeRl: rl => unit = "close"
@set external setWriteToOutput: (rl, string => unit) => unit = "_writeToOutput"

// ── Shared interface ──────────────────────────────────────────────────────────

// Created on first use, closed once via `close`. `muted` gates the echo so the
// same interface serves both visible and hidden prompts.
let rlRef: ref<option<rl>> = ref(None)
let muted = ref(false)

let iface = (): rl =>
  switch rlRef.contents {
  | Some(rl) => rl
  | None =>
    let rl = createInterface({input: NodeProcess.stdin, output: NodeProcess.stdout, terminal: true})
    rl->setWriteToOutput(s =>
      if !muted.contents {
        NodeProcess.stdout->NodeProcess.write(s)
      }
    )
    rlRef := Some(rl)
    rl
  }

let close = (): unit =>
  switch rlRef.contents {
  | Some(rl) =>
    rl->closeRl
    rlRef := None
    // Closing the interface is not enough: a terminal-mode readline leaves
    // NodeProcess.stdin resumed and reffed, which keeps the event loop alive so the CLI
    // never exits after seeding. Release it explicitly.
    NodeProcess.stdin->NodeProcess.pause
    NodeProcess.stdin->NodeProcess.unref
  | None => ()
  }

// ── Env + TTY ─────────────────────────────────────────────────────────────────

let envValue = (key: string): option<string> =>
  switch NodeProcess.env->Dict.get(key) {
  | Some(v) if v->String.trim != "" => Some(v->String.trim)
  | _ => None
  }

let requireTty = (): unit =>
  if !(NodeProcess.stdin->NodeProcess.isTTY->Option.getOr(false)) {
    throw(
      Failed(
        "no TTY for an interactive prompt — set the documented SEED_* / REVENTLESS_DEMO_* " ++
        "env vars to run non-interactively.",
      ),
    )
  }

// ── Prompts ───────────────────────────────────────────────────────────────────

let ask = (query: string): promise<string> =>
  Promise.make((resolve, _) => {
    let rl = iface()
    rl->question(query, answer => resolve(answer->String.trim))
  })

// Same interface, echo suppressed for the keystrokes. `question` writes the
// prompt synchronously first (while unmuted), then muting is switched on so only
// the typed characters are hidden — the canonical readline recipe, which keeps
// the line editor's cursor state consistent (a manual write + empty `question`
// left some terminals unable to read the next line).
let askHidden = (query: string): promise<string> =>
  Promise.make((resolve, _) => {
    let rl = iface()
    rl->question(query, answer => {
      muted := false
      NodeProcess.stdout->NodeProcess.write("\n")
      resolve(answer)
    })
    muted := true
  })

/**
 * Whether an answer means yes — the one vocabulary, for the typed reply and the
 * env var that stands in for it alike.
 *
 * It exists because those two drifted: a `[y/N]` prompt took `y`, and the env
 * var beside it took only `1` or `yes`, so the obvious `SEED_RESET_CONFIRM=y`
 * silently fell through to the interactive branch — which, on the CI runs the
 * variable exists for, has no TTY and throws. Two spellings of one question are
 * one spelling too many; callers ask this instead of comparing strings.
 *
 * Trimmed and case-folded, so `Yes`/` y ` answer the same as `y`.
 */
let isAffirmative = (answer: string): bool =>
  switch answer->String.trim->String.toLowerCase {
  | "y" | "yes" | "1" => true
  | _ => false
  }

/**
 * Chooses one of `options` (a label paired with the value it selects).
 *
 * Auto-returns when there is a single option, so a lone data set or stack needs
 * no keypress. `env` (e.g. `SEED_SET`) preselects by matching label or 1-based
 * index, so CI runs without a TTY. Otherwise it prints a numbered menu.
 */
let select = async (
  ~title: string,
  ~options: array<(string, 'a)>,
  ~env=?,
): 'a =>
  switch options {
  | [(_, only)] => only
  | _ =>
    let fromEnv =
      env
      ->Option.flatMap(envValue)
      ->Option.flatMap(v =>
        switch options->Array.findIndex(((label, _)) => label == v) {
        | -1 =>
          switch Int.fromString(v) {
          | Some(n) if n >= 1 && n <= options->Array.length => options->Array.get(n - 1)
          | _ => None
          }
        | i => options->Array.get(i)
        }
      )
    switch fromEnv {
    | Some((_, value)) => value
    | None =>
      requireTty()
      Console.log("")
      Console.log(title)
      Console.log("")
      options->Array.forEachWithIndex(((label, _), i) =>
        Console.log(`  ${(i + 1)->Int.toString}) ${label}`)
      )
      let rec pick = async (): 'a => {
        let answer = await ask(`\nSelect [1-${(options->Array.length)->Int.toString}]: `)
        switch Int.fromString(answer) {
        | Some(n) if n >= 1 && n <= options->Array.length =>
          let (_, value) = options->Array.getUnsafe(n - 1)
          value
        | _ =>
          Console.log("  Not a valid choice.")
          await pick()
        }
      }
      await pick()
    }
  }

/**
 * Prompts for a username (visible) and password (echo muted).
 *
 * `REVENTLESS_DEMO_USER` / `REVENTLESS_DEMO_PASSWORD` skip the prompts. With
 * `localDefaults`, empty input falls back to `admin`/`admin` — the dev login.
 */
let credentials = async (~localDefaults: bool=false): (string, string) => {
  let username = switch envValue("REVENTLESS_DEMO_USER") {
  | Some(u) => u
  | None =>
    requireTty()
    let entered = await ask(localDefaults ? "Username [admin]: " : "Username: ")
    entered == "" && localDefaults ? "admin" : entered
  }
  let password = switch envValue("REVENTLESS_DEMO_PASSWORD") {
  | Some(p) => p
  | None =>
    requireTty()
    let entered = await askHidden(localDefaults ? "Password [admin]: " : "Password: ")
    entered == "" && localDefaults ? "admin" : entered
  }
  if username == "" || password == "" {
    throw(Failed("username and password are required."))
  }
  (username, password)
}
