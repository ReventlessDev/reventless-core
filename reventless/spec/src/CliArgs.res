/***
How every command-line tool in this repository reads `process.argv`: through
Node's `parseArgs`, with mistakes worded the way these tools word them, and one
behaviour on `--help`, on a usage mistake and on a bare invocation (see [run]).
Non-strict with tokens rather than strict mode, because strict mode names the
offending argument only inside English prose.
*/

/** An undeclared `--key` under `~pairs=true`: with a value, or on its own. */
type value =
  | Text(string)
  | Present

type t = {
  values: NodeUtil.values,
  positionals: array<string>,
  pairs: array<(string, value)>,
}

/** A usage mistake. A tool that ran and failed exits 1, so a caller can tell a
    misinvocation from a run whose answer was no. */
let usageMistakeExit = 2

let unknown = (arg: string) => `unknown argument "${arg}"`

/** A positional the tool has no place for, worded like any other unknown argument. */
let extra = (arg: string): result<'a, string> => Error(unknown(arg))

/** `-` alone is a value (stdin, by convention); anything else starting with a
    dash is the next flag, which a string option must not swallow. */
let flagShaped = (value: string) => value->String.startsWith("-") && value != "-"

/** Package managers can forward a bare `--` ahead of a script's own arguments.
    Anywhere else it ends the options, as POSIX says. */
let withoutLeadingTerminator = (argv: array<string>) =>
  argv->Array.get(0) == Some("--") ? argv->Array.slice(~start=1, ~end=Array.length(argv)) : argv

/** Parse against the declared options. `-h`/`--help` is declared for every
    tool. The first mistake in argv order is the one reported. Under
    `~pairs=true` an undeclared long option is kept as a `(key, value)` pair
    instead of refused, taking the argument after it as its value when that
    argument is not itself an option. */
let parse = (
  ~strings: array<string>=[],
  ~bools: array<string>=[],
  ~lists: array<string>=[],
  ~pairs: bool=false,
  argv: array<string>,
): result<t, string> => {
  let args = withoutLeadingTerminator(argv)
  let options: dict<NodeUtil.optionConfig> = Dict.make()
  options->Dict.set("help", {type_: Boolean, short: "h"})
  bools->Array.forEach(name => options->Dict.set(name, {type_: Boolean}))
  strings->Array.forEach(name => options->Dict.set(name, {type_: String}))
  lists->Array.forEach(name => options->Dict.set(name, {type_: String, multiple: true}))

  let parsed = NodeUtil.parseArgs({
    args,
    options,
    strict: false,
    allowPositionals: true,
    tokens: true,
  })
  let tokens = parsed.tokens->Option.getOr([])
  let positionals = []
  let found = []

  // Non-strict `parseArgs` types an undeclared option as a boolean and emits
  // the argument after it as the next positional token, so a pair's value is
  // read back from token order.
  let rec walk = i =>
    switch tokens->Array.get(i) {
    | None => Ok()
    | Some(token) =>
      switch token.kind {
      | Terminator => walk(i + 1)
      | Positional =>
        positionals->Array.push(token.value->Option.getOr(""))
        walk(i + 1)
      | Flag =>
        let name = token.name->Option.getOr("")
        let rawName = token.rawName->Option.getOr(name)
        let inline = token.inlineValue->Option.getOr(false)
        switch (options->Dict.get(name), token.value) {
        | (Some({type_: String}), None) => Error(`${rawName} needs a value`)
        | (Some({type_: String}), Some(v)) if !inline && flagShaped(v) =>
          Error(`${rawName} needs a value`)
        | (Some({type_: Boolean}), Some(_)) => Error(`${rawName} takes no value`)
        | (Some(_), _) => walk(i + 1)
        | (None, _) if !pairs || !(rawName->String.startsWith("--")) => Error(unknown(rawName))
        | (None, Some(v)) =>
          found->Array.push((name, Text(v)))
          walk(i + 1)
        | (None, None) =>
          switch tokens->Array.get(i + 1) {
          | Some({kind: Positional, index, value: ?Some(v)}) if index == token.index + 1 =>
            found->Array.push((name, Text(v)))
            walk(i + 2)
          | _ =>
            found->Array.push((name, Present))
            walk(i + 1)
          }
        }
      }
    }

  walk(0)->Result.map(() => {values: parsed.values, positionals, pairs: found})
}

let string = (t: t, name: string): option<string> => t.values->NodeUtil.string(name)
let bool = (t: t, name: string): bool => t.values->NodeUtil.bool(name)->Option.getOr(false)
let strings = (t: t, name: string): array<string> =>
  t.values->NodeUtil.strings(name)->Option.getOr([])
let positionals = (t: t): array<string> => t.positionals
let pairs = (t: t): array<(string, value)> => t.pairs
let help = (t: t): bool => t->bool("help")

/** For a tool that takes at most `max` positionals: the first beyond them is
    refused as [extra]. */
let atMost = (t: t, max: int): result<t, string> =>
  switch t.positionals->Array.get(max) {
  | None => Ok(t)
  | Some(arg) => extra(arg)
  }

let noPositionals = (t: t): result<t, string> => t->atMost(0)

/** Whether `-h` or `--help` appears before any `--` that ends the options.
    Read off argv rather than a parse, so it answers even when the other
    arguments are wrong. */
let asksForHelp = (argv: array<string>): bool => {
  let argv = withoutLeadingTerminator(argv)
  let options = switch argv->Array.indexOf("--") {
  | -1 => argv
  | end => argv->Array.slice(~start=0, ~end)
  }
  options->Array.some(arg => arg == "-h" || arg == "--help")
}

/** A tool's command line: its name, its usage (first line `Usage: <bin> …`),
    and how it turns argv into its arguments. */
type cli<'args> = {
  bin: string,
  usage: string,
  parse: array<string> => result<'args, string>,
}

/** Where [run] writes and how it ends the process, so a test can watch it. */
type io = {
  out: string => unit,
  err: string => unit,
  exit: int => unit,
}

let processIo = {
  out: text => Console.log(text),
  err: text => Console.error(text),
  exit: NodeProcess.exit,
}

/** Help anywhere prints the usage to stdout and exits 0, whatever else is
    wrong. A usage mistake prints `<bin>: <message>`, a blank line and the usage
    to stderr and exits 2. Otherwise `main` gets the arguments, and its own
    failures keep their exit 1. */
let run = async (
  cli: cli<'args>,
  ~argv: option<array<string>>=?,
  ~io: io=processIo,
  main: 'args => promise<unit>,
): unit => {
  let argv =
    argv->Option.getOr(NodeProcess.argv->Array.slice(~start=2, ~end=NodeProcess.argv->Array.length))
  let usage = cli.usage->String.trim
  if asksForHelp(argv) {
    io.out(usage)
    io.exit(0)
  } else {
    switch cli.parse(argv) {
    | Error(message) =>
      io.err(`${cli.bin}: ${message}\n\n${usage}`)
      io.exit(usageMistakeExit)
    | Ok(args) => await main(args)
    }
  }
}

/** What [run] did with one argv, for a tool's own tests. */
type observed = {
  stdout: array<string>,
  stderr: array<string>,
  exitCode: option<int>,
  reachedMain: bool,
}

/** Run a tool's command line without a process: nothing is printed, nothing
    exits, and `main` is not called — only whether it would have been. */
let observe = async (cli: cli<'args>, argv: array<string>): observed => {
  let stdout = []
  let stderr = []
  let exitCode = ref(None)
  let reachedMain = ref(false)
  let io = {
    out: text => stdout->Array.push(text),
    err: text => stderr->Array.push(text),
    exit: code => exitCode := Some(code),
  }
  await run(cli, ~argv, ~io, async _ => reachedMain := true)
  {stdout, stderr, exitCode: exitCode.contents, reachedMain: reachedMain.contents}
}
