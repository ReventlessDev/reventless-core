open JestGlobals

let parse = (argv, ~pairs=false) =>
  CliArgs.parse(~strings=["manifest", "stack"], ~bools=["update"], ~lists=["root"], ~pairs, argv)

let positionalsOf = argv => parse(argv)->Result.map(CliArgs.positionals)

describe("CliArgs.parse refuses", () => {
  testSync("an option nobody declared, in the tools' wording", () =>
    expect(parse(["--stak", "alpha"])->Result.map(_ => ()))->toEqual(
      Error(`unknown argument "--stak"`),
    )
  )

  testSync("the first mistake in argv order", () =>
    expect(parse(["--nope", "--manifest"])->Result.map(_ => ()))->toEqual(
      Error(`unknown argument "--nope"`),
    )
  )

  testSync("an undeclared short option", () =>
    expect(parse(["-x"])->Result.map(_ => ()))->toEqual(Error(`unknown argument "-x"`))
  )

  testSync("a string option with no value", () =>
    expect(parse(["--manifest"])->Result.map(_ => ()))->toEqual(Error("--manifest needs a value"))
  )

  // Node would take `--stack` as the manifest; nobody who typed this meant that.
  testSync("a string option whose value is the next flag", () =>
    expect(parse(["up", "--manifest", "--stack", "try"])->Result.map(_ => ()))->toEqual(
      Error("--manifest needs a value"),
    )
  )

  testSync("a value on a boolean option", () =>
    expect(parse(["--update=yes"])->Result.map(_ => ()))->toEqual(Error("--update takes no value"))
  )
})

describe("CliArgs.parse accepts", () => {
  testSync("--flag value and --flag=value alike", () => {
    let read = argv =>
      parse(argv)->Result.map(a => (a->CliArgs.string("manifest"), a->CliArgs.string("stack")))
    expect(read(["--manifest", "m.yaml", "--stack", "try"]))->toEqual(
      Ok((Some("m.yaml"), Some("try"))),
    )
    expect(read(["--manifest=m.yaml", "--stack=try"]))->toEqual(Ok((Some("m.yaml"), Some("try"))))
  })

  testSync("a flag-shaped value given inline, which is unambiguous", () =>
    expect(parse(["--manifest=--odd"])->Result.map(a => a->CliArgs.string("manifest")))->toEqual(
      Ok(Some("--odd")),
    )
  )

  testSync("a lone dash as a value", () =>
    expect(parse(["--manifest", "-"])->Result.map(a => a->CliArgs.string("manifest")))->toEqual(
      Ok(Some("-")),
    )
  )

  testSync("an empty value", () =>
    expect(parse(["--stack", ""])->Result.map(a => a->CliArgs.string("stack")))->toEqual(
      Ok(Some("")),
    )
  )

  testSync("a boolean, absent as false", () => {
    expect(parse(["--update"])->Result.map(a => a->CliArgs.bool("update")))->toEqual(Ok(true))
    expect(parse([])->Result.map(a => a->CliArgs.bool("update")))->toEqual(Ok(false))
  })

  testSync("a repeated list option, in order", () =>
    expect(
      parse(["--root", "a", "--root=b"])->Result.map(a => a->CliArgs.strings("root")),
    )->toEqual(Ok(["a", "b"]))
  )

  testSync("-h and --help, declared for every tool", () => {
    expect(parse(["-h"])->Result.map(CliArgs.help))->toEqual(Ok(true))
    expect(parse(["--help"])->Result.map(CliArgs.help))->toEqual(Ok(true))
    expect(parse([])->Result.map(CliArgs.help))->toEqual(Ok(false))
  })

  testSync("positionals, in order, wherever they sit", () =>
    expect(positionalsOf(["up", "--stack", "try", "down"]))->toEqual(Ok(["up", "down"]))
  )
})

describe("CliArgs.parse and --", () => {
  testSync("a leading -- is dropped and parsing continues", () =>
    expect(parse(["--", "--update"])->Result.map(a => a->CliArgs.bool("update")))->toEqual(Ok(true))
  )

  testSync("anywhere else it ends the options", () => {
    let parsed = parse(["a", "--", "--update"])
    expect(parsed->Result.map(a => a->CliArgs.bool("update")))->toEqual(Ok(false))
    expect(parsed->Result.map(CliArgs.positionals))->toEqual(Ok(["a", "--update"]))
  })
})

describe("CliArgs.parse with pairs", () => {
  // `graft-trait`'s reading: every undeclared --key is a field of the trait's
  // config, with the argument after it as its value unless that is a flag.
  testSync("undeclared keys become pairs in argv order", () => {
    let parsed = parse(
      [
        "@scope/trait-x",
        "--manifest",
        "m",
        "--entity",
        "Customer",
        "--primary",
        "--fields=a,b",
        "--values",
        `email: "a@x.y"`,
        "--last",
      ],
      ~pairs=true,
    )
    expect(parsed->Result.map(CliArgs.pairs))->toEqual(
      Ok([
        ("entity", CliArgs.Text("Customer")),
        ("primary", CliArgs.Present),
        ("fields", CliArgs.Text("a,b")),
        ("values", CliArgs.Text(`email: "a@x.y"`)),
        ("last", CliArgs.Present),
      ]),
    )
    expect(parsed->Result.map(CliArgs.positionals))->toEqual(Ok(["@scope/trait-x"]))
    expect(parsed->Result.map(a => a->CliArgs.string("manifest")))->toEqual(Ok(Some("m")))
  })

  testSync("a key before -- takes no value from beyond it", () =>
    expect(parse(["--flag", "--", "x"], ~pairs=true)->Result.map(CliArgs.pairs))->toEqual(
      Ok([("flag", CliArgs.Present)]),
    )
  )

  testSync("an undeclared short option is still refused", () =>
    expect(parse(["-x"], ~pairs=true)->Result.map(_ => ()))->toEqual(Error(`unknown argument "-x"`))
  )
})

describe("CliArgs.extra", () => {
  testSync("words a surplus positional like an unknown argument", () =>
    expect(CliArgs.extra("down"))->toEqual((Error(`unknown argument "down"`): result<unit, string>))
  )

  testSync("noPositionals refuses the first positional the same way", () =>
    expect(
      parse(["--update", "stray", "more"])
      ->Result.flatMap(CliArgs.noPositionals)
      ->Result.map(_ => ()),
    )->toEqual(Error(`unknown argument "stray"`))
  )
})

// ── run ─────────────────────────────────────────────────────────────────────

type captured = {out: array<string>, err: array<string>, exits: array<int>, ran: array<string>}

let tool: CliArgs.cli<option<string>> = {
  bin: "tool",
  usage: "\nUsage: tool [--stack <name>]\n\n  --stack <name>  the stack\n",
  parse: argv =>
    CliArgs.parse(~strings=["stack"], argv)->Result.flatMap(a =>
      switch a->CliArgs.positionals {
      | [] => Ok(a->CliArgs.string("stack"))
      | surplus => CliArgs.extra(surplus->Array.getUnsafe(0))
      }
    ),
}

let runTool = async (~main=?, argv) => {
  let c = {out: [], err: [], exits: [], ran: []}
  let io: CliArgs.io = {
    out: text => c.out->Array.push(text),
    err: text => c.err->Array.push(text),
    exit: code => c.exits->Array.push(code),
  }
  let main = switch main {
  | Some(main) => main(io)
  | None => async stack => c.ran->Array.push(stack->Option.getOr("default"))
  }
  await CliArgs.run(tool, ~argv, ~io, main)
  c
}

let usage = "Usage: tool [--stack <name>]\n\n  --stack <name>  the stack"

describe("CliArgs.run", () => {
  test("help anywhere prints the usage to stdout and exits 0", async () => {
    let c = await runTool(["--stack", "x", "-h"])
    expect(c)->toEqual({out: [usage], err: [], exits: [0], ran: []})
  })

  test("help wins over an argument that is wrong", async () => {
    let c = await runTool(["--nope", "--help"])
    expect(c)->toEqual({out: [usage], err: [], exits: [0], ran: []})
  })

  test("help after the options have ended is an argument, not a request", async () => {
    let c = await runTool(["x", "--", "--help"])
    expect((c.out, c.exits))->toEqual(([], [2]))
  })

  test("a usage mistake: message, blank line, usage on stderr, exit 2, stdout empty", async () => {
    let c = await runTool(["--nope"])
    expect(c)->toEqual({
      out: [],
      err: [`tool: unknown argument "--nope"\n\n${usage}`],
      exits: [2],
      ran: [],
    })
  })

  test("parsed arguments go to main, and nothing exits", async () => {
    let c = await runTool(["--stack", "try"])
    expect(c)->toEqual({out: [], err: [], exits: [], ran: ["try"]})
  })

  test("main's own failure keeps its exit 1", async () => {
    let c = await runTool(~main=io => async _ => io.exit(1), [])
    expect(c.exits)->toEqual([1])
  })
})

describe("CliArgs.observe", () => {
  test("reports what run would do, without doing it", async () => {
    expect(await CliArgs.observe(tool, ["--stack", "try"]))->toEqual({
      CliArgs.stdout: [],
      stderr: [],
      exitCode: None,
      reachedMain: true,
    })
    expect(await CliArgs.observe(tool, ["--nope"]))->toEqual({
      CliArgs.stdout: [],
      stderr: [`tool: unknown argument "--nope"\n\n${usage}`],
      exitCode: Some(2),
      reachedMain: false,
    })
  })
})
