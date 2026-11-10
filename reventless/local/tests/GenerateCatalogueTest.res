open JestGlobals

// The catalogue tool's command line: generating a plugin's English, and the app's status,
// check and mark.

let parse = argv => GenerateCatalogue.parseArgs(argv)

describe("generate-catalogue arguments", () => {
  testSync("a source directory generates, as before", () =>
    expect(parse(["src", "--check"]))->toEqual(
      Ok(GenerateCatalogue.Generate({srcDir: "src", check: true})),
    )
  )

  testSync("status and check take the layers in merge order", () =>
    expect((
      parse(["status", "a/i18n", "b/i18n"]),
      parse(["check", "a/i18n", "--languages", "l.json"]),
    ))->toEqual((
      Ok(GenerateCatalogue.Status({dirs: ["a/i18n", "b/i18n"]})),
      Ok(GenerateCatalogue.Check({dirs: ["a/i18n"], languages: "l.json"})),
    ))
  )

  testSync("mark takes a language, the layers, keys and --confirmed", () =>
    expect(
      parse(["mark", "de", "a/i18n", "--key", "A.*", "--key", "B.c.name", "--confirmed"]),
    )->toEqual(
      Ok(
        GenerateCatalogue.Mark({
          language: "de",
          dirs: ["a/i18n"],
          keys: ["A.*", "B.c.name"],
          confirmed: true,
        }),
      ),
    )
  )

  testSync("refuses a status without layers and a mark of the source language", () =>
    expect((
      parse(["status"])->Result.isError,
      parse(["mark", "en", "a/i18n"])->Result.isError,
      parse(["mark"])->Result.isError,
    ))->toEqual((true, true, true))
  )
})
