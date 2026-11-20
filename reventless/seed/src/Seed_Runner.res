// Run orchestration: progress output, view verification, and failure reporting.

open Seed_Types

let envOr = (key: string, fallback: string): string =>
  NodeProcess.env->Dict.get(key)->Option.getOr(fallback)

/** One line of progress per phase, so a slow run never looks hung. */
let report = (line: string): unit => Console.log(`  ${line}`)

let heading = (line: string): unit => {
  Console.log("")
  Console.log(line)
}

/**
 * A view the seed is expected to fill, or one it demonstrably cannot.
 *
 * Splitting them matters: an unexpected empty view means the seed missed a
 * component, which is exactly the "is it broken or is it empty?" ambiguity
 * seeding exists to remove — so it fails the run. A view listed as unfillable
 * reports its reason instead, so a zero is never mistaken for a gap.
 */
type view =
  | Seeded(string)
  | Unfillable(string, string)

let viewName = (v: view): string =>
  switch v {
  | Seeded(name) => name
  | Unfillable(name, _) => name
  }

/**
 * Counts every view and fails if one that should have rows is empty.
 * Returns the counts so callers can fold them into their own summary.
 */
let verifyViews = async (client: Seed_Client.t, ~views: array<view>): dict<int> => {
  let counts = Dict.make()
  for i in 0 to views->Array.length - 1 {
    switch views->Array.get(i) {
    | Some(v) =>
      let name = v->viewName
      counts->Dict.set(name, await Seed_Client.countNodes(client, ~field=name))
    | None => ()
    }
  }

  heading("View row counts:")
  views->Array.forEach(v => {
    let name = v->viewName
    let count = counts->Dict.get(name)->Option.getOr(0)
    let note = switch v {
    | Unfillable(_, _) => "  (known empty — see warning below)"
    | Seeded(_) => ""
    }
    Console.log(`  ${count->Int.toString->String.padStart(4, " ")}  ${name}${note}`)
  })

  let empty = views->Array.filterMap(v =>
    switch v {
    | Seeded(name) if counts->Dict.get(name)->Option.getOr(0) == 0 => Some(name)
    | _ => None
    }
  )
  if empty->Array.length > 0 {
    throw(Failed(`these views are still empty after seeding: ${empty->Array.join(", ")}`))
  }
  counts
}

/** Collects the reasons for any view that legitimately could not be filled. */
let unfillableWarnings = (~views: array<view>, ~counts: dict<int>): array<string> =>
  views->Array.filterMap(v =>
    switch v {
    | Unfillable(name, reason) if counts->Dict.get(name)->Option.getOr(0) == 0 =>
      Some(`${name} is empty: ${reason}.`)
    | _ => None
    }
  )

let warn = (warnings: array<string>): unit =>
  if warnings->Array.length > 0 {
    heading("WARNING — the dataset is complete, but not everything could be filled:")
    warnings->Array.forEach(w => Console.log(`  - ${w}`))
  }

/**
 * Pre-flight: refuse to seed onto a store that already holds data.
 *
 * The harness is a one-shot against a fresh store — a re-run would hit the
 * domain's own duplicate rejections (`CategoryAlreadyExists`, …) and abort
 * mid-phase. Catching it here, before any command is sent, turns that into an
 * honest "nothing was written" startup abort instead of a misleading
 * half-seeded one. It is the inverse of `verifyViews`: seeding refuses to start
 * unless the store reads empty. Stops at the first non-empty probe view, so a
 * populated store aborts after a single query.
 */
let assertStoreEmpty = async (client: Seed_Client.t, ~probeViews: array<string>): unit =>
  for i in 0 to probeViews->Array.length - 1 {
    switch probeViews->Array.get(i) {
    | Some(name) =>
      let count = await Seed_Client.countNodes(client, ~field=name)
      if count > 0 {
        throw(
          Failed(
            `the target store is not empty — "${name}" already holds ${count->Int.toString} row(s). Seeding is a one-shot against a fresh store; reset the store before re-running.`,
          ),
        )
      }
    | None => ()
    }
  }

/**
 * Wraps a seed run. On failure it prints the cause and exits non-zero, saying
 * plainly that the store is now half-seeded — recovery is a reset, not a re-run.
 */
let run = async (main: unit => promise<unit>): unit =>
  try {
    await main()
    // Exit cleanly: HTTP keep-alive sockets (and, on the interactive path, the
    // readline/stdin handle) can otherwise keep the event loop alive so the CLI
    // appears to hang after a successful run.
    NodeProcess.exit(0)
  } catch {
  | Failed(message) =>
    Console.error("")
    Console.error("Seeding aborted — the store is now half-seeded; re-run against a")
    Console.error("fresh store once the cause below is fixed.")
    Console.error("")
    Console.error(message)
    NodeProcess.exit(1)
  | exn =>
    Console.error("")
    Console.error("Seeding aborted with an unexpected error:")
    Console.error("")
    Console.error(exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown"))
    NodeProcess.exit(1)
  }

// See `Seed_DataSet`.
type dataSet = Seed_DataSet.t = {
  name: string,
  label: string,
  seed: Seed_Connect.connection => promise<unit>,
  probeViews?: array<string>,
  preflight?: Seed_Connect.connection => promise<unit>,
  repeatable?: bool,
  pace?: string,
}

/** How many times a run plays its set: `SEED_REPEAT`, a count or `forever`. */
type repeat = Times(int) | Forever

let repeatFromEnv = (): repeat =>
  switch Seed_Prompt.envValue("SEED_REPEAT") {
  | None => Times(1)
  | Some(raw) =>
    switch (raw->String.toLowerCase, Int.fromString(raw)) {
    | ("forever", _) => Forever
    | (_, Some(n)) if n >= 1 => Times(n)
    | _ =>
      throw(Failed(`SEED_REPEAT="${raw}" is not a count — expected a number from 1, or forever`))
    }
  }

/** The pace a run plays `set` at: `SEED_PACE`, else the set's own, else none. */
let paceFor = (set: dataSet): option<Seed_Pace.t> =>
  switch Seed_Prompt.envValue("SEED_PACE")->Option.orElse(set.pace) {
  | None => None
  | Some(text) =>
    switch Seed_Pace.parse(text) {
    | Ok(pace) => Some(pace)
    | Error(message) => throw(Failed(`SEED_PACE: ${message}`))
    }
  }

/** Why `set` cannot be played `repeat` times, if it cannot. */
let refuseRepeat = (set: dataSet, repeat: repeat): option<string> =>
  switch (repeat, set.repeatable, set.probeViews) {
  | (Times(1), _, _) => None
  | (_, Some(true), None | Some([])) => None
  | (_, Some(true), Some(_)) =>
    Some(`"${set.name}" refuses a store that holds data, so it cannot run more than once`)
  | (_, _, _) => Some(`"${set.name}" is not repeatable — it would send the same ids again`)
  }

let errorMessage = (exn: exn): string =>
  switch exn {
  | Failed(message) => message
  | exn => exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
  }

/**
 * Plays a set again and again. The first SIGINT or SIGTERM lets the repetition
 * in progress finish, so the store holds only whole repetitions; a second stops
 * at once and says which repetition it cut short. What the platform does after
 * the last command (an automation reacting) goes on without the player.
 */
let play = async (set: dataSet, connection: Seed_Connect.connection, ~repeat: repeat): unit => {
  let stopAsked = ref(false)
  let current = ref(0)
  let onSignal = () =>
    if stopAsked.contents {
      Console.error("")
      Console.error(
        `Stopped at once — repetition ${current.contents->Int.toString} was cut short; ` ++ `the ones before it are whole.`,
      )
      NodeProcess.exit(130)
    } else {
      stopAsked := true
      Console.log("")
      Console.log(
        `  stopping after repetition ${current.contents->Int.toString} finishes (signal again to stop now)`,
      )
    }
  NodeProcess.onSignal(SIGINT, onSignal)
  NodeProcess.onSignal(SIGTERM, onSignal)
  let more = () =>
    !stopAsked.contents &&
    switch repeat {
    | Forever => true
    | Times(n) => current.contents < n
    }
  while more() {
    current := current.contents + 1
    heading(`Repetition ${current.contents->Int.toString}`)
    try await set.seed(connection) catch {
    | exn =>
      Console.error("")
      Console.error(
        `Repetition ${current.contents->Int.toString} stopped part way; the ${(current.contents - 1)
            ->Int.toString} before it are whole.`,
      )
      Console.error("")
      Console.error(errorMessage(exn))
      NodeProcess.exit(1)
    }
  }
  heading(
    `Played ${current.contents->Int.toString} repetition(s), ${connection.client
      ->Seed_Client.sentCount
      ->Int.toString} commands${stopAsked.contents ? ", stopped on request" : ""}.`,
  )
  NodeProcess.exit(0)
}

/**
 * A failure before any command is sent — bad data-set selection, an
 * unreachable/undeployed target, a login failure. Nothing was written, so this
 * says so plainly rather than warning about a half-seeded store (which would
 * send the user resetting a store the run never touched).
 */
let abortStartup = (message: string): unit => {
  Seed_Prompt.close()
  Console.error("")
  Console.error("Seeding did not start — nothing was written. Fix the cause below and re-run.")
  Console.error("")
  Console.error(message)
  NodeProcess.exit(1)
}

/**
 * Top-level seed entry: choose a data set (auto when there is one, `SEED_SET`
 * or a menu otherwise), connect, then hand the connection to the chosen set.
 * Prompts are closed before seeding so the shared readline never lingers.
 *
 * Selection and connect run before any command is sent, so a failure there is
 * reported as "did not start"; only failures inside the data set's own `seed`
 * carry the half-seeded warning (via `run`).
 */
let seed = (~sets: array<dataSet>, ~connect: unit => promise<Seed_Connect.connection>): unit => {
  let go = async () => {
    let started = try {
      // `SEED_FILE` plays a file instead of the app's own sets (see `Seed_Play`).
      let sets = switch Seed_Prompt.envValue("SEED_FILE") {
      | Some(path) => [Seed_Play.dataSet(~path)]
      | None => sets
      }
      let chosen = switch sets {
      | [only] => only
      | _ =>
        switch Seed_Prompt.envValue("SEED_SET") {
        | Some(wanted) =>
          switch sets->Array.find(s => s.name == wanted) {
          | Some(s) => s
          | None =>
            throw(
              Failed(
                `SEED_SET="${wanted}" matches no data set (have: ${sets
                  ->Array.map(s => s.name)
                  ->Array.join(", ")})`,
              ),
            )
          }
        | None =>
          await Seed_Prompt.select(~title="Data set:", ~options=sets->Array.map(s => (s.label, s)))
        }
      }
      let repeat = repeatFromEnv()
      switch refuseRepeat(chosen, repeat) {
      | Some(message) => throw(Failed(message))
      | None => ()
      }
      let pace = paceFor(chosen)
      let connection = await connect()
      connection.client->Seed_Client.usePace(pace)
      Seed_Prompt.close()
      // Runs inside this pre-seed `try`, so refusing a non-empty store (or a
      // failed probe query) is reported as "did not start", not "half-seeded".
      await assertStoreEmpty(connection.client, ~probeViews=chosen.probeViews->Option.getOr([]))
      switch chosen.preflight {
      | Some(check) => await check(connection)
      | None => ()
      }
      Some((chosen, connection, repeat, pace))
    } catch {
    | Failed(message) =>
      abortStartup(message)
      None
    | exn =>
      abortStartup(exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown"))
      None
    }
    switch started {
    | None => () // unreachable: abortStartup has already exited
    | Some((chosen, connection, repeat, pace)) =>
      let paceNote = pace->Option.mapOr("", p => ` at ${p.text}`)
      heading(`Seeding "${chosen.label}" into ${connection.label}${paceNote}`)
      switch repeat {
      | Times(1) => await run(() => chosen.seed(connection))
      | _ => await play(chosen, connection, ~repeat)
      }
    }
  }
  go()->ignore
}
