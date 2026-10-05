/***
Before `pulumi up`, recovers a stack an interrupted deploy left behind: releases a
stale lock, drops the pending creates known to have nothing in AWS behind them,
and refreshes. Any other pending operation stops it: `--clear-pending-creates`
drops them all, and would orphan a function or a role that does exist.
*/

/** Resource types with nothing in AWS behind them, so a pending create of one is
    safe to drop. Add one only when that holds; a refusal costs one look, an
    orphan stays until someone finds it. */
let safeTypes = [
  // ACM's wait for DNS validation, which gives up after 1h15m when the record is late.
  "aws:acm/certificateValidation:CertificateValidation",
]

type pending = {urn: string, resourceType: string, operation: string}

let pendingOperations = (export: JSON.t): array<pending> => {
  let field = (json, name) => json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(name))
  let text = (json, name) => json->field(name)->Option.flatMap(JSON.Decode.string)->Option.getOr("")
  export
  ->field("deployment")
  ->Option.flatMap(deployment => deployment->field("pending_operations"))
  ->Option.flatMap(JSON.Decode.array)
  ->Option.getOr([])
  ->Array.map(operation => {
    let resource = operation->field("resource")->Option.getOr(JSON.Null)
    {
      urn: resource->text("urn"),
      resourceType: resource->text("type"),
      operation: operation->text("type"),
    }
  })
}

let isSafe = (pending: pending) => safeTypes->Array.includes(pending.resourceType)

type args = {stack: string, cwd: string}

let parseArgs = (argv: array<string>): result<args, string> =>
  Reventless.CliArgs.parse(~strings=["stack", "cwd"], argv)
  ->Result.flatMap(Reventless.CliArgs.noPositionals)
  ->Result.flatMap(a =>
    switch a->Reventless.CliArgs.string("stack") {
    | Some(stack) =>
      Ok({stack, cwd: a->Reventless.CliArgs.string("cwd")->Option.getOr(NodeProcess.cwd())})
    | None => Error("--stack names the stack to recover")
    }
  )

let usage = `
Usage: clear-pending-creates --stack <name> [--cwd <dir>]

Recovers a stack before \`pulumi up\`: cancels a stale update, drops the pending
creates of types with nothing in AWS behind them, and refreshes. Any other pending
operation fails the command, for someone to resolve by hand.

  --stack <name>   The stack.
  --cwd <dir>      The Pulumi project. Defaults to the working directory.
`

let pulumi = (args: args, command: array<string>) =>
  NodeChildProcess.spawnSync(
    "pulumi",
    command->Array.concat(["--stack", args.stack, "--cwd", args.cwd, "--non-interactive"]),
    {encoding: "utf8", maxBuffer: 256 * 1024 * 1024},
  )

let succeeded = (result: NodeChildProcess.spawnSyncResult) =>
  result.status->Nullable.toOption == Some(0)

let stderrOf = (result: NodeChildProcess.spawnSyncResult) =>
  result.stderr->Nullable.toOption->Option.getOr("")->String.trim

let run = (args: args): result<unit, array<string>> => {
  let cancel = pulumi(args, ["cancel", "--yes"])
  switch stderrOf(cancel) {
  | message
    if !succeeded(cancel) &&
    message != "" &&
    !(message->String.toLowerCase->String.includes("no update in progress")) =>
    Console.error(`::warning::pulumi cancel: ${message}`)
  | _ => ()
  }
  let exported = pulumi(args, ["stack", "export"])
  let state = switch exported.stdout->Nullable.toOption {
  | Some(stdout) if succeeded(exported) =>
    try Ok(JSON.parseOrThrow(stdout)) catch {
    | _ => Error([`the export of stack ${args.stack} is not JSON`])
    }
  | _ => Error([`pulumi stack export failed: ${stderrOf(exported)}`])
  }
  state->Result.flatMap(state => {
    let pending = pendingOperations(state)
    let refused = pending->Array.filter(p => !isSafe(p))
    if pending == [] {
      Console.log(`No pending operations on stack ${args.stack}.`)
    } else {
      Console.log(
        `${pending->Array.length->Int.toString} pending operation(s) on stack ${args.stack}.`,
      )
    }
    if refused != [] {
      Error(
        refused->Array.map(p =>
          `Pending ${p.operation} of ${p.urn} (${p.resourceType}): not cleared, because something may exist in AWS behind it. Resolve it by hand, or, if the type has nothing behind it, add it to ClearPendingCreates.safeTypes.`
        ),
      )
    } else {
      // Every pending operation left is safe, so the refresh may drop them all.
      // `pulumi state delete` cannot: a pending create has no resource in the state.
      pending->Array.forEach(p =>
        Console.log(`::warning::Clearing pending ${p.operation} of ${p.urn} (${p.resourceType})`)
      )
      let clear = pending == [] ? [] : ["--clear-pending-creates"]
      // A failed refresh is usually a stale provider serialization, which the
      // `pulumi up` after this heals.
      let refreshed = pulumi(args, ["refresh", "--yes", "--skip-preview"]->Array.concat(clear))
      if !succeeded(refreshed) {
        Console.error(
          `::warning::pulumi refresh had errors; pulumi up runs anyway. ${stderrOf(refreshed)}`,
        )
      }
      Ok()
    }
  })
}

let cli: Reventless.CliArgs.cli<args> = {bin: "clear-pending-creates", usage, parse: parseArgs}

let main = () =>
  Reventless.CliArgs.run(cli, async args =>
    switch run(args) {
    | Ok() => ()
    | Error(messages) =>
      messages->Array.forEach(message => Console.error(`::error::${message}`))
      NodeProcess.exit(1)
    }
  )

// No top-level call: `../run-clear-pending-creates.mjs` invokes [main], so a test
// can import this module.
