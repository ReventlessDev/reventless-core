// Runner-side self-tests. Constructs synthetic `Outcome` values and feeds
// them through `RenderRescript`, `Diff`, and `FormatterJson` / `FormatterTap`
// to assert the rendered shapes. This is the unit-test layer — CLI-level
// integration is covered by running `node bin/reventless-gwt.mjs run tests/`
// against the DSL worked-example suites.

open AsyncTest
open AsyncTest.Expect

let encodeString = (s: string): JSON.t => JSON.Encode.string(s)

let makeTaggedEvent = (~tag: string, ~payload: JSON.t): JSON.t => {
  let d = Dict.make()
  d->Dict.set("TAG", JSON.Encode.string(tag))
  d->Dict.set("_0", payload)
  JSON.Encode.object(d)
}

describe("RenderRescript", () => {
  testPromise("renders tagged variants with BuckleScript representation", async () => {
    let payload = Dict.make()
    payload->Dict.set("name", encodeString("Electronics"))
    let ev = makeTaggedEvent(~tag="CategoryAdded", ~payload=JSON.Encode.object(payload))
    let rendered = RenderRescript.render(ev)
    expect(rendered)->toEqual(`CategoryAdded({name: "Electronics"})`)
  })

  testPromise("renders payload-less variants as bare strings", async () => {
    let ev = JSON.Encode.string("CategoryArchived")
    expect(RenderRescript.render(ev))->toEqual(`"CategoryArchived"`)
  })

  testPromise("renders plain records in field order", async () => {
    let d = Dict.make()
    d->Dict.set("id", encodeString("c1"))
    d->Dict.set("count", JSON.Encode.int(3))
    let rendered = RenderRescript.render(JSON.Encode.object(d))
    expect(rendered)->toEqual(`{id: "c1", count: 3}`)
  })

  testPromise("renderMany splits large arrays across lines", async () => {
    let a = makeTaggedEvent(~tag="A", ~payload=JSON.Encode.object(Dict.make()))
    let b = makeTaggedEvent(~tag="B", ~payload=JSON.Encode.object(Dict.make()))
    let rendered = RenderRescript.renderMany([a, b])
    expect(rendered->String.includes("A({})"))->toEqual(true)
    expect(rendered->String.includes("B({})"))->toEqual(true)
  })

  // Inline-record variants (`Name({...})`) are flattened by ReScript: the record
  // fields sit beside TAG, not under `_0`. Regression for the dropped-payload bug
  // where `ProductsNotAvailable({missing: [...]})` rendered as bare
  // `ProductsNotAvailable`, making error diffs read `X != X`.
  testPromise("renders inline-record variants with their flattened payload", async () => {
    let d = Dict.make()
    d->Dict.set("TAG", encodeString("ProductsNotAvailable"))
    d->Dict.set("missing", JSON.Encode.array([encodeString("p1x")]))
    let rendered = RenderRescript.render(JSON.Encode.object(d))
    expect(rendered)->toEqual(`ProductsNotAvailable({missing: ["p1x"]})`)
  })

  testPromise("renders multi-field inline-record variants", async () => {
    let d = Dict.make()
    d->Dict.set("TAG", encodeString("Conflict"))
    d->Dict.set("expected", JSON.Encode.int(1))
    d->Dict.set("got", JSON.Encode.int(2))
    let rendered = RenderRescript.render(JSON.Encode.object(d))
    expect(rendered)->toEqual(`Conflict({expected: 1, got: 2})`)
  })
})

describe("Diff", () => {
  testPromise("emits one entry per differing leaf", async () => {
    let d1 = Dict.make()
    d1->Dict.set("name", encodeString("A"))
    d1->Dict.set("count", JSON.Encode.int(1))
    let d2 = Dict.make()
    d2->Dict.set("name", encodeString("B"))
    d2->Dict.set("count", JSON.Encode.int(1))
    let diff = Diff.diff(JSON.Encode.object(d1), JSON.Encode.object(d2))
    expect(diff->Array.length)->toEqual(1)
    let first = diff->Array.getUnsafe(0)
    expect(first.path)->toEqual("name")
  })

  testPromise("emits zero entries when values are identical", async () => {
    let d = Dict.make()
    d->Dict.set("a", JSON.Encode.int(1))
    let left = JSON.Encode.object(d)
    let d2 = Dict.make()
    d2->Dict.set("a", JSON.Encode.int(1))
    let right = JSON.Encode.object(d2)
    expect(Diff.diff(left, right)->Array.length)->toEqual(0)
  })
})

describe("FormatterJson.mismatchJson", () => {
  testPromise("ErrorMismatch carries dual-rendered expected + actualEvents", async () => {
    // Payload-less variants encode to a bare JSON string — matches sury's
    // default representation.
    let expectedError = JSON.Encode.string("CategoryAlreadyExists")
    let actualEvent = {
      let p = Dict.make()
      p->Dict.set("categoryId", encodeString("c1"))
      p->Dict.set("name", encodeString("X"))
      makeTaggedEvent(~tag="CategoryAdded", ~payload=JSON.Encode.object(p))
    }
    let m = Outcome.ErrorMismatch({
      expected: expectedError,
      actual: None,
      actualEvents: [actualEvent],
    })
    let j = FormatterJson.mismatchJson(m, Some("AddCategory"))
    let str = JSON.stringify(j)
    expect(str->String.includes(`"kind":"ErrorMismatch"`))->toEqual(true)
    // Payload-less variant's `type` field carries the constructor name.
    expect(str->String.includes(`"type":"CategoryAlreadyExists"`))->toEqual(true)
    expect(
      str->String.includes(`CategoryAdded({categoryId: \\\"c1\\\", name: \\\"X\\\"})`),
    )->toEqual(true)
    expect(str->String.includes(`"locus":"AddCategory.decide"`))->toEqual(true)
  })

  testPromise("EventsMismatch includes a fieldDiff derived from payloads", async () => {
    let expected = {
      let p = Dict.make()
      p->Dict.set("name", encodeString("Electronics"))
      [makeTaggedEvent(~tag="Added", ~payload=JSON.Encode.object(p))]
    }
    let actual = {
      let p = Dict.make()
      p->Dict.set("name", encodeString("Books"))
      [makeTaggedEvent(~tag="Added", ~payload=JSON.Encode.object(p))]
    }
    let m = Outcome.EventsMismatch({expected, actual})
    let j = FormatterJson.mismatchJson(m, None)
    let str = JSON.stringify(j)
    expect(str->String.includes(`"fieldDiff"`))->toEqual(true)
    expect(str->String.includes(`"path":"0._0.name"`))->toEqual(true)
  })
})

describe("Cli.parseArgv", () => {
  testPromise("parses run subcommand with --format=json --filter=Foo", async () => {
    let argv = [
      "/bin/node",
      "/path/to/bin",
      "run",
      "--format=json",
      "--filter=Foo",
      "tests/",
    ]
    switch Cli.parseArgv(argv) {
    | Ok(opts) => {
        expect(opts.subcommand == Run)->toEqual(true)
        expect(opts.format == Json)->toEqual(true)
        expect(opts.filters)->toEqual(["Foo"])
        expect(opts.roots)->toEqual(["tests/"])
      }
    | Error(msg) => JsError.throwWithMessage("expected Ok, got: " ++ msg)
    }
  })

  testPromise("discover subcommand defaults to vscode format", async () => {
    let argv = ["/bin/node", "/path/to/bin", "discover"]
    switch Cli.parseArgv(argv) {
    | Ok(opts) => {
        expect(opts.subcommand == Discover)->toEqual(true)
        expect(opts.format == VsCode)->toEqual(true)
      }
    | Error(msg) => JsError.throwWithMessage("expected Ok, got: " ++ msg)
    }
  })

  testPromise("unknown flag reports an error", async () => {
    let argv = ["/bin/node", "/path/to/bin", "run", "--nonsense"]
    switch Cli.parseArgv(argv) {
    | Ok(_) => JsError.throwWithMessage("expected Error")
    | Error(msg) => expect(msg->String.includes("Unknown flag"))->toEqual(true)
    }
  })

  testPromise("no path argument defaults to the cwd subtree (auto-discovery)", async () => {
    let argv = ["/bin/node", "/path/to/bin", "watch", "--format=vscode"]
    switch Cli.parseArgv(argv) {
    | Ok(opts) => {
        expect(opts.subcommand == Watch)->toEqual(true)
        expect(opts.roots)->toEqual(["."])
      }
    | Error(msg) => JsError.throwWithMessage("expected Ok, got: " ++ msg)
    }
  })

  testPromise("platform backend defaults to memory; --backend overrides", async () => {
    switch Cli.parseArgv(["/bin/node", "/path/to/bin", "platform", "--format=vscode"]) {
    | Ok(opts) => {
        expect(opts.subcommand == Platform)->toEqual(true)
        expect(opts.backend)->toEqual("memory")
      }
    | Error(msg) => JsError.throwWithMessage("expected Ok, got: " ++ msg)
    }
    switch Cli.parseArgv(["/bin/node", "/path/to/bin", "platform", "--backend=sqlite:./db?reset"]) {
    | Ok(opts) => expect(opts.backend)->toEqual("sqlite:./db?reset")
    | Error(msg) => JsError.throwWithMessage("expected Ok, got: " ++ msg)
    }
  })
})
