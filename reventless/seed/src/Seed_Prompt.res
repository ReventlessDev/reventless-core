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
 *
 * `defaultIndex` makes Enter a valid answer, selecting that 0-based option;
 * without one every reply must name a choice.
 */
let select = async (
  ~title: string,
  ~options: array<(string, 'a)>,
  ~env=?,
  ~defaultIndex=?,
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
      let fallback = defaultIndex->Option.flatMap(i => options->Array.get(i))
      let hint = switch (defaultIndex, fallback) {
      | (Some(i), Some(_)) => ` (default ${(i + 1)->Int.toString})`
      | _ => ""
      }
      let rec pick = async (): 'a => {
        let answer = await ask(
          `\nSelect [1-${(options->Array.length)->Int.toString}]${hint}: `,
        )
        switch (answer, fallback) {
        | ("", Some((_, value))) => value
        | _ =>
          switch Int.fromString(answer) {
          | Some(n) if n >= 1 && n <= options->Array.length =>
            let (_, value) = options->Array.getUnsafe(n - 1)
            value
          | _ =>
            Console.log("  Not a valid choice.")
            await pick()
          }
        }
      }
      await pick()
    }
  }

// Typing both halves is the fallback, not the first offer: it is what happens
// when the platform keeps no accounts file. `envUser` is threaded in so a
// `REVENTLESS_DEMO_USER` that named nobody in the file still skips the username
// prompt rather than asking for a name that was already given.
let askCredentials = async (~localDefaults: bool, ~envUser: option<string>): (string, string) => {
  let username = switch envUser {
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
  (username, password)
}

// The accounts file the platform already keeps (`.reventless/users.yaml`, or
// `SEED_USERS_FILE`). It records the password beside the username, so choosing
// an account is the whole credential step — nothing is typed.
//
// A named `REVENTLESS_DEMO_USER` picks its entry directly; otherwise the file's
// accounts are offered in the order it defines them, first as the default.
// `None` means the file has nothing to offer and the caller should ask.
let fromUsersFile = async (~envUser: option<string>): option<(string, string)> =>
  switch Seed_Users.load(~path=?envValue("SEED_USERS_FILE")) {
  | None => None
  | Some((path, users)) =>
    let chosen = switch envUser {
    | Some(name) => users->Array.find(u => u.username == name)
    | None =>
      Some(
        await select(
          ~title=`User (${path}):`,
          ~options=users->Array.map(u => (Seed_Users.label(u), u)),
          ~env="SEED_USER",
          ~defaultIndex=0,
        ),
      )
    }
    // Logged for every arm, including the single-account file that selects
    // itself without a keypress: which identity seeded the data is the thing an
    // operator checks when owner-scoped rows turn up under the wrong account.
    chosen->Option.map(u => {
      Console.log(`Logging in as ${u.username} (from ${path})`)
      (u.username, u.password)
    })
  }

/**
 * Resolves the credentials a seed run logs in with.
 *
 * `REVENTLESS_DEMO_USER` + `REVENTLESS_DEMO_PASSWORD` together are the
 * non-interactive path and skip everything below. Otherwise the platform's
 * `.reventless/users.yaml` supplies the accounts to choose from, and only a
 * platform without one falls back to typing both halves — where, with
 * `localDefaults`, empty input means `admin`/`admin`.
 */
let credentials = async (~localDefaults: bool=false): (string, string) => {
  let envUser = envValue("REVENTLESS_DEMO_USER")
  let (username, password) = switch (envUser, envValue("REVENTLESS_DEMO_PASSWORD")) {
  | (Some(u), Some(p)) => (u, p)
  | _ =>
    switch await fromUsersFile(~envUser) {
    | Some(pair) => pair
    | None => await askCredentials(~localDefaults, ~envUser)
    }
  }
  if username == "" || password == "" {
    throw(Failed("username and password are required."))
  }
  (username, password)
}
