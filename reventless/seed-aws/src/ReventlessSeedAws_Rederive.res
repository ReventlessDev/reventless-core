// Backfills the dates a lifecycle trail derives on a deployed stack's view rows.
//
// A row saved before its view derived them carries a trail and none of
// `_entered_<State>`, `_visits_<State>`, `_entered_current` or `_trail`, so the
// indexes built on them leave it out until its next write. This writes them from
// the trail, with the same function a save uses. A dry run is the default.
//
// Unlike the rest of the seed packages this depends on reventless-spec: the
// derived attributes are computed by `Lifecycle.Trail`, never restated here.

open ReventlessSeed

module Ddb = AwsSdk.DynamoDb
module Rgt = AwsSdk.ResourceGroupsTaggingApi
module Trail = Reventless.Lifecycle.Trail

// ── One row ──────────────────────────────────────────────────────────────────

/** The update that brings one row's derived attributes in line with its trail,
    or None when they already are. It touches only the derived attributes, and
    only while the trail still has the length it had when the row was read: a
    row written since then already got them from its save. */
let updateFor = (~table: string, ~keyAttrs: array<string>, row: dict<JSON.t>): option<
  Ddb.DocumentClient.UpdateCommand.input,
> =>
  switch row->Trail.fieldOfRow {
  | None => None
  | Some(field) =>
    let change = row->Trail.rederive(~field)
    if change->Trail.isUnchanged {
      None
    } else {
      let names = Dict.make()
      let values = Dict.make()
      let sets =
        change.set
        ->Dict.toArray
        ->Array.mapWithIndex(((attr, value), i) => {
          names->Dict.set(`#s${i->Int.toString}`, attr)
          values->Dict.set(`:s${i->Int.toString}`, value)
          `#s${i->Int.toString} = :s${i->Int.toString}`
        })
      let removes = change.remove->Array.mapWithIndex((attr, i) => {
        names->Dict.set(`#r${i->Int.toString}`, attr)
        `#r${i->Int.toString}`
      })
      names->Dict.set("#trail", field)
      let length = switch row->Dict.get(field) {
      | Some(Array(entries)) => entries->Array.length
      | _ => 0
      }
      values->Dict.set(":length", JSON.Encode.int(length))
      let clauses =
        [
          sets->Array.length > 0 ? Some("SET " ++ sets->Array.join(", ")) : None,
          removes->Array.length > 0 ? Some("REMOVE " ++ removes->Array.join(", ")) : None,
        ]->Array.filterMap(c => c)
      Some({
        tableName: table,
        key: keyAttrs
        ->Array.filterMap(k => row->Dict.get(k)->Option.map(v => (k, v)))
        ->Dict.fromArray,
        updateExpression: clauses->Array.join(" "),
        conditionExpression: "size(#trail) = :length",
        expressionAttributeNames: names,
        expressionAttributeValues: values,
      })
    }
  }

// ── One table ────────────────────────────────────────────────────────────────

type outcome = Updated | Skipped

/** What a table backfill reads and writes through, so a test can stand in. */
type ops = {
  scan: option<dict<JSON.t>> => promise<(array<dict<JSON.t>>, option<dict<JSON.t>>)>,
  update: Ddb.DocumentClient.UpdateCommand.input => promise<outcome>,
}

type tally = {
  table: string,
  rows: int,
  withTrail: int,
  toChange: int,
  updated: int,
  /** Written between the scan and the update; their save already derived them. */
  skipped: int,
}

let rederiveTable = async (
  ~table: string,
  ~keyAttrs: array<string>,
  ~apply: bool,
  ops: ops,
): tally => {
  let tally = ref({table, rows: 0, withTrail: 0, toChange: 0, updated: 0, skipped: 0})
  let rec loop = async (start: option<dict<JSON.t>>): unit => {
    let (items, next) = await ops.scan(start)
    await items->Array.reduce(Promise.resolve(), (acc, row) =>
      acc->Promise.then(async _ => {
        let t = tally.contents
        let withTrail = row->Trail.fieldOfRow->Option.isSome
        let t = {...t, rows: t.rows + 1, withTrail: t.withTrail + (withTrail ? 1 : 0)}
        tally :=
          switch updateFor(~table, ~keyAttrs, row) {
          | None => t
          | Some(input) =>
            let t = {...t, toChange: t.toChange + 1}
            if apply {
              switch await ops.update(input) {
              | Updated => {...t, updated: t.updated + 1}
              | Skipped => {...t, skipped: t.skipped + 1}
              }
            } else {
              t
            }
          }
      })
    )
    switch next {
    | Some(_) => await loop(next)
    | None => ()
    }
  }
  await loop(None)
  tally.contents
}

let awsOps = (~table: string): ops => {
  scan: async start => {
    let out = await Ddb.DocumentClient.ScanCommand.send(
      Ddb.DocumentClient.ScanCommand.make({tableName: table, exclusiveStartKey: ?start}),
    )
    (out.items->Option.getOr([])->Array.filterMap(JSON.Decode.object), out.lastEvaluatedKey)
  },
  update: async input =>
    switch await Ddb.DocumentClient.UpdateCommand.send(
      Ddb.DocumentClient.UpdateCommand.make(input),
    ) {
    | _ => Updated
    | exception exn =>
      switch exn->JsExn.fromException->Option.flatMap(JsExn.name) {
      | Some("ConditionalCheckFailedException") => Skipped
      | _ => throw(exn)
      }
    },
}

let keyAttrsOf = async (~table: string): array<string> => {
  let out = await Ddb.DynamoDb.DescribeTableCommand.send(
    Ddb.DynamoDb.DescribeTableCommand.make({tableName: table}),
  )
  out.table
  ->Option.flatMap(t => t.keySchema)
  ->Option.getOr([])
  ->Array.map(k => k.attributeName)
}

// ── A stack ──────────────────────────────────────────────────────────────────

/** A project's view tables: those its stack tagged as QueryDb stores, re-checked
    per table the way the reset checks what it empties. */
let viewTables = async (~region, ~stack, ~platform): array<string> => {
  let client = Rgt.client(~region, ())
  let tables = []
  let rec loop = async (token: option<string>): unit => {
    let out = await Rgt.GetResourcesCommand.send(
      client,
      Rgt.GetResourcesCommand.make({
        tagFilters: [
          {key: "reventless:platform", values: [platform]},
          {key: "reventless:environment", values: [stack]},
          {key: "reventless:role", values: ["QueryDb"]},
        ],
        resourceTypeFilters: ["dynamodb:table"],
        resourcesPerPage: 100,
        paginationToken: ?token,
      }),
    )
    out.resourceTagMappingList
    ->Option.getOr([])
    ->Array.forEach(m => {
      let tags = m.tags->Option.getOr([])
      let tagged = (key, expected) => ReventlessSeedAws_Reset.tagValue(tags, key) == Some(expected)
      if !(tagged("reventless:platform", platform) && tagged("reventless:environment", stack)) {
        throw(Seed.Failed(`refusing: ${m.resourceARN} is outside stack "${stack}" of ${platform}.`))
      }
      switch ReventlessSeedAws_Reset.classify(m.resourceARN) {
      | Table(name) => tables->Array.push(name)
      | _ => ()
      }
    })
    switch out.paginationToken {
    | Some(t) if t != "" => await loop(Some(t))
    | _ => ()
    }
  }
  await loop(None)
  tables->Array.toSorted(String.compare)
}

let print = (t: tally, ~apply: bool) =>
  Console.log(
    `  ${t.table->String.padEnd(36, " ")} rows ${t.rows->Int.toString->String.padStart(6, " ")}` ++
    `  with a trail ${t.withTrail->Int.toString->String.padStart(6, " ")}` ++ if apply {
      `  updated ${t.updated->Int.toString}  skipped ${t.skipped->Int.toString}`
    } else {
      `  to change ${t.toChange->Int.toString}`
    },
  )

/**
 * Backfill the derived trail dates on every view table of a deployed stack.
 *
 * `targets` are the deployment's Pulumi projects, as `Reset.run` takes them;
 * each one's tables are found by its stack's tags. Reads only, unless the
 * command line carries `--apply`.
 */
let run = (~stack=?, ~backend=?, ~targets: array<ReventlessSeedAws_Reset.target>, ()): unit => {
  let go = async () => {
    try {
      let apply = NodeProcess.argv->Array.includes("--apply")
      let backend = switch Seed.Prompt.envValue("SEED_PULUMI_BACKEND") {
      | Some(url) => Some(url)
      | None => backend
      }
      let first = switch targets->Array.get(0) {
      | Some(t) => t
      | None => throw(Seed.Failed("no targets were declared — nothing to backfill."))
      }
      let stack = await ReventlessSeedAws.resolveStack(
        ~projectDir=first.projectDir,
        ~backend,
        ~stack,
      )
      let region = switch Seed.Prompt.envValue("AWS_REGION") {
      | Some(r) if r != "" => r
      | _ => throw(Seed.Failed("could not resolve the AWS region — set AWS_REGION."))
      }
      Seed.Runner.heading(
        `Trail dates: stack "${stack}" in ${region}${apply ? "" : " (dry run; --apply writes)"}`,
      )
      let pending = ref(0)
      await targets->Array.reduce(Promise.resolve(), (acc, target) =>
        acc->Promise.then(async _ => {
          let platform = ReventlessSeedAws_Reset.projectName(~projectDir=target.projectDir)
          let tables = await viewTables(~region, ~stack, ~platform)
          Console.log("")
          Console.log(`${target.label} (${platform})`)
          if tables->Array.length == 0 {
            Console.log("  (no view tables)")
          }
          await tables->Array.reduce(
            Promise.resolve(),
            (acc, table) =>
              acc->Promise.then(
                async _ => {
                  let keyAttrs = await keyAttrsOf(~table)
                  let tally = await rederiveTable(~table, ~keyAttrs, ~apply, awsOps(~table))
                  if tally.withTrail > 0 {
                    print(tally, ~apply)
                  }
                  pending := pending.contents + (apply ? 0 : tally.toChange)
                },
              ),
          )
        })
      )
      Console.log("")
      Console.log(
        apply
          ? "Done. A second run should find nothing to change."
          : `${pending.contents->Int.toString} row(s) to change. Re-run with --apply to write them.`,
      )
      NodeProcess.exit(0)
    } catch {
    | Seed.Failed(message) =>
      Console.error("")
      Console.error(`Backfill failed — ${message}`)
      NodeProcess.exit(1)
    | exn =>
      Console.error("")
      Console.error("Backfill failed with an unexpected error:")
      Console.error(
        exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown"),
      )
      NodeProcess.exit(1)
    }
  }
  go()->ignore
}
