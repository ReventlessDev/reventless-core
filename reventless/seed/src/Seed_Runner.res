// Run orchestration: progress output, view verification, and failure reporting.

open Seed_Types

@scope("process") @val external exit: int => unit = "exit"
@scope("process") @val external env: dict<string> = "env"

let envOr = (key: string, fallback: string): string =>
  env->Dict.get(key)->Option.getOr(fallback)

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

  let empty =
    views
    ->Array.filterMap(v =>
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
 * Wraps a seed run. On failure it prints the cause and exits non-zero, saying
 * plainly that the store is now half-seeded — recovery is a reset, not a re-run.
 */
let run = async (main: unit => promise<unit>): unit =>
  try await main() catch {
  | Failed(message) =>
    Console.error("")
    Console.error("Seeding aborted — the store is now half-seeded; re-run against a")
    Console.error("fresh store once the cause below is fixed.")
    Console.error("")
    Console.error(message)
    exit(1)
  | exn =>
    Console.error("")
    Console.error("Seeding aborted with an unexpected error:")
    Console.error("")
    Console.error(
      exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown"),
    )
    exit(1)
  }
