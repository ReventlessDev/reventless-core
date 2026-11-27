/***
Tags the stored events of the kinds a deploy began to read whole, once per table, and counts their
fences. Until it runs, a whole read sees only the events written since the deploy.
*/

type args = {
  table: string,
  kinds: array<string>,
  dryRun: bool,
  settleMs: int,
}

let parseArgs = (argv: array<string>): result<args, string> =>
  Reventless.CliArgs.parse(~strings=["table", "kinds", "settle-ms"], ~bools=["dry-run"], argv)
  ->Result.flatMap(Reventless.CliArgs.noPositionals)
  ->Result.flatMap(a => {
    let kinds =
      a
      ->Reventless.CliArgs.string("kinds")
      ->Option.mapOr([], k => k->String.split(",")->Array.map(String.trim))
      ->Array.filter(k => k != "")
    let settleMs = a->Reventless.CliArgs.string("settle-ms")->Option.map(s => Int.fromString(s))
    switch (a->Reventless.CliArgs.string("table"), kinds, settleMs) {
    | (None, _, _) => Error("--table names the DCB event log table")
    | (_, [], _) =>
      Error("--kinds names the event types read whole (the dcb-scope golden lists them)")
    | (_, _, Some(None)) => Error("--settle-ms takes a whole number of milliseconds")
    | (Some(table), kinds, settleMs) =>
      Ok({
        table,
        kinds,
        dryRun: a->Reventless.CliArgs.bool("dry-run"),
        settleMs: settleMs->Option.flatMap(x => x)->Option.getOr(2000),
      })
    }
  })

let usage = `
Usage: tag-kinds --table <name> --kinds <EventType,...> [--dry-run] [--settle-ms <n>]

Tags the stored events of each kind a slice reads whole (@readWhole) with the kind
tag, moves the kind's fence, and then counts the fence as count-fences does. Run it
once after the deploy that began reading the kind whole, when every Lambda runs the
new code. Each event is tagged once; running it again tags nothing new.

  --table <name>        The DCB event log table.
  --kinds <Type,...>    The event types read whole (the dcb-scope golden lists them).
  --dry-run             Count what it would tag, write nothing.
  --settle-ms <n>       How long the index gets to show the tags. Default 2000.
`

let run = async (args: args): result<unit, array<string>> => {
  let table: Util_DynamoDb_Runtime.resolvedTable = {
    id: "",
    name: args.table,
    arn: "",
    hashKey: "id",
  }
  let tagged = await DcbKindBackfill.tagKinds(table, ~eventTypes=args.kinds, ~dryRun=args.dryRun)
  tagged->Array.forEach(((eventType, n)) =>
    Console.log(`${args.dryRun ? "would tag" : "tagged"} ${n->Int.toString} ${eventType} event(s)`)
  )
  if args.dryRun {
    Ok()
  } else {
    let (outcomes, _) = await DcbFenceBackfill.countAll(
      table,
      ~keys=[Reventless.DcbTag.kindTagKey],
      ~pairs=[],
      ~recount=true,
      ~settleMs=args.settleMs,
      ~dryRun=false,
    )
    let failures = outcomes->Array.filterMap(((ref, outcome)) => {
      let fence = DcbFenceBackfill.fenceRefText(ref)
      switch outcome {
      | Ok(Counted(_)) =>
        Console.log(`counted ${fence}`)
        None
      | Ok(Moved) => Some(`${fence}: writers kept moving it; run count-fences again`)
      | Ok(IndexBehind(_)) => Some(`${fence}: the index is behind; run count-fences again`)
      | Error(message) => Some(`${fence}: ${message}`)
      }
    })
    failures == [] ? Ok() : Error(failures)
  }
}

let cli: Reventless.CliArgs.cli<args> = {bin: "tag-kinds", usage, parse: parseArgs}

let main = () =>
  Reventless.CliArgs.run(cli, async args =>
    switch await run(args) {
    | Ok() => ()
    | Error(messages) =>
      messages->Array.forEach(message => Console.error(message))
      NodeProcess.exit(1)
    }
  )

// No top-level call: `../run-tag-kinds.mjs` invokes [main], so a test can import this module.
