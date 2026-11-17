/***
Completes the counts of a DCB event log's cross-partition fences, once per table
after the deploy that began counting. Until a fence is counted, readers check it
by position as before.
*/

type args = {
  table: string,
  keys: array<string>,
  pairs: array<(string, string)>,
  dryRun: bool,
  recount: bool,
  settleMs: int,
}

let parseArgs = (argv: array<string>): result<args, string> =>
  Reventless.CliArgs.parse(
    ~strings=["table", "keys", "pairs", "settle-ms"],
    ~bools=["dry-run", "recount"],
    argv,
  )
  ->Result.flatMap(Reventless.CliArgs.noPositionals)
  ->Result.flatMap(a => {
    let keys =
      a
      ->Reventless.CliArgs.string("keys")
      ->Option.mapOr([], k => k->String.split(",")->Array.map(String.trim))
      ->Array.filter(k => k != "")
    let pairs =
      a
      ->Reventless.CliArgs.string("pairs")
      ->Option.mapOr([], p => p->String.split(",")->Array.map(String.trim))
      ->Array.filter(p => p != "")
      ->Array.map(p =>
        switch p->String.split(":") {
        | [key, eventType] if key != "" && eventType != "" => Some((key, eventType))
        | _ => None
        }
      )
    let settleMs = a->Reventless.CliArgs.string("settle-ms")->Option.map(s => Int.fromString(s))
    switch (a->Reventless.CliArgs.string("table"), keys, pairs, settleMs) {
    | (None, _, _, _) => Error("--table names the DCB event log table")
    | (_, [], [], _) =>
      Error(
        "--keys or --pairs names what to count: cross-partition tag keys, or key:EventType pairs",
      )
    | (_, _, pairs, _) if pairs->Array.some(Option.isNone) =>
      Error("--pairs takes key:EventType, comma-separated")
    | (_, _, _, Some(None)) => Error("--settle-ms takes a whole number of milliseconds")
    | (Some(table), keys, pairs, settleMs) =>
      Ok({
        table,
        keys,
        pairs: pairs->Array.filterMap(p => p),
        dryRun: a->Reventless.CliArgs.bool("dry-run"),
        recount: a->Reventless.CliArgs.bool("recount"),
        settleMs: settleMs->Option.flatMap(x => x)->Option.getOr(2000),
      })
    }
  })

let usage = `
Usage: count-fences --table <name> [--keys <key,...>] [--pairs <key:EventType,...>] [--dry-run] [--recount] [--settle-ms <n>]

Completes the counts of the cross-partition fences of a DCB event log table: counts
every event of each type that carries the fence's tag, sets the fence's counts to
that and marks it counted, on condition that no writer moved it meanwhile. Run it
once after the deploy that began counting. A fence that is not counted is checked
by position, as before.

  --table <name>     The DCB event log table.
  --keys <key,...>   The cross-partition tag keys (the dcb-scope golden lists them).
  --pairs <key:EventType,...>
                     The pairs' fences, by key and event type (the golden lists the
                     pairs). At least one of --keys and --pairs.
  --dry-run          Count and print, write nothing.
  --recount          Count fences already counted too, to repair one.
  --settle-ms <n>    How long the index gets to show earlier writes. Default 2000.
`

let countsText = (counts: dict<int>) =>
  switch counts->Dict.toArray {
  | [] => "none"
  | pairs => pairs->Array.map(((t, n)) => `${t}=${n->Int.toString}`)->Array.join(" ")
  }

let run = async (args: args): result<unit, array<string>> => {
  let table: Util_DynamoDb_Runtime.resolvedTable = {
    id: "",
    name: args.table,
    arn: "",
    hashKey: "id",
  }
  let fences = await DcbFenceBackfill.listFences(
    table,
    ~keys=args.keys,
    ~pairs=args.pairs,
    ~recount=args.recount,
  )
  Console.log(`${fences->Array.length->Int.toString} fence(s) to count in ${args.table}.`)
  let outcomes = await DcbFenceBackfill.countFences(
    table,
    fences,
    ~settleMs=args.settleMs,
    ~dryRun=args.dryRun,
  )
  let failures = outcomes->Array.filterMap(((ref, outcome)) => {
    let fence = DcbFenceBackfill.fenceRefText(ref)
    switch outcome {
    | Ok(Counted({before, total})) =>
      Console.log(
        `${args.dryRun ? "would count" : "counted"} ${fence}: ${countsText(before)} -> ${countsText(
            total,
          )}`,
      )
      None
    | Ok(Moved) => Some(`${fence}: writers kept moving it; run again`)
    | Ok(IndexBehind({before, total})) =>
      Some(
        `${fence}: the index shows ${countsText(total)}, fewer than counted (${countsText(
            before,
          )}); run again`,
      )
    | Error(message) => Some(`${fence}: ${message}`)
    }
  })
  failures == [] ? Ok() : Error(failures)
}

let cli: Reventless.CliArgs.cli<args> = {bin: "count-fences", usage, parse: parseArgs}

let main = () =>
  Reventless.CliArgs.run(cli, async args =>
    switch await run(args) {
    | Ok() => ()
    | Error(messages) =>
      messages->Array.forEach(message => Console.error(message))
      NodeProcess.exit(1)
    }
  )

// No top-level call: `../run-count-fences.mjs` invokes [main], so a test can
// import this module.
