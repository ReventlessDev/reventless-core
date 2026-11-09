open JestGlobals

// The catalogues the local platform serves, and the `languages` it names in `config.json`.
// Every failure here is quiet: a catalogue that is not served reads as a translation that does
// nothing, and a language named without a catalogue reads as one the app never offered.

let _ = TestRunner.setup()

let tmpdir = prefix => NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), prefix]))

/** A source directory holding the given `<lang>.json` files. */
let source = (files: array<(string, string)>) => {
  let dir = tmpdir("reventless-i18n-src-")
  files->Array.forEach(((language, text)) =>
    NodeFs.writeFileSync(NodePath.join([dir, language ++ ".json"]), text)
  )
  dir
}

let plugin = source([
  ("en", `{"Ordering.Orders.name": "Order", "Ordering.Orders.plural": "Orders"}`),
  ("de", `{"Ordering.Orders.name": "Bestellung", "Ordering.Orders.plural": "Bestellungen"}`),
])
// The app rewords one plugin text in German and has no English overrides.
let app = source([("de", `{"Ordering.Orders.name": "Auftrag"}`)])

let declared: ReventlessInfra.Platform.i18n = {
  default: "de",
  offered: ["en"],
  sources: [plugin, app],
}

let served = (dir, language) =>
  NodeFs.readFileSync(NodePath.join([dir, "i18n", language ++ ".json"]))->JSON.parseOrThrow

let threw = (f: unit => unit): option<string> =>
  try {
    f()
    None
  } catch {
  | JsExn(e) => e->JsExn.message
  }

describe("Platform_I18n", () => {
  testSync("the default joins the offered languages", () =>
    expect(ReventlessCore.Platform_I18n.validate(declared)->Result.map(v => v.offered))->toEqual(
      Ok(["de", "en"]),
    )
  )

  testSync("a tag that is not one, and a register that is not Sie or du, are refused", () => {
    expect(
      ReventlessCore.Platform_I18n.validate({...declared, offered: ["en_GB"]})->Result.isError,
    )->toBe(true)
    expect(
      ReventlessCore.Platform_I18n.validate({...declared, register: "Du"})->Result.isError,
    )->toBe(true)
  })

  testSync("config.json reads the languages as the shell expects them", () =>
    expect(
      ReventlessCore.Platform_I18n.configEntry({
        ...declared,
        offered: ["de", "en"],
        register: "du",
      }),
    )->toEqual((
      "languages",
      JSON.parseOrThrow(`{"default": "de", "offered": ["de", "en"], "register": "du"}`),
    ))
  )
})

describe("I18n.emit", () => {
  testSync("serves one catalogue per language, a later source winning a key", () => {
    let dist = tmpdir("reventless-i18n-dist-")
    I18n.emit(~i18n=Some(declared), ~dir=dist)
    expect((served(dist, "de"), served(dist, "en")))->toEqual((
      JSON.parseOrThrow(`{"Ordering.Orders.name": "Auftrag", "Ordering.Orders.plural": "Bestellungen"}`),
      JSON.parseOrThrow(`{"Ordering.Orders.name": "Order", "Ordering.Orders.plural": "Orders"}`),
    ))
  })

  testSync("a platform that stops declaring catalogues serves none", () => {
    let dist = tmpdir("reventless-i18n-dist-")
    I18n.emit(~i18n=Some(declared), ~dir=dist)
    I18n.emit(~i18n=None, ~dir=dist)
    expect(NodeFs.existsSync(NodePath.join([dist, "i18n"])))->toBe(false)
  })

  testSync("a source that is not JSON stops the platform, naming the file", () => {
    let broken = source([("de", "{not json")])
    let message = threw(
      () =>
        I18n.emit(
          ~i18n=Some({...declared, sources: [broken]}),
          ~dir=tmpdir("reventless-i18n-dist-"),
        ),
    )
    expect(message->Option.mapOr(false, m => m->String.includes("de.json is not JSON")))->toBe(true)
  })
})

describe("ShellConfig.overlay with catalogues", () => {
  testSync("names the languages", () =>
    expect(
      ShellConfig.overlay(~bakedManifest=None, ~shellConfig=None, ~i18n=declared)->Dict.get(
        "languages",
      ),
    )->toEqual(Some(JSON.parseOrThrow(`{"default": "de", "offered": ["de", "en"]}`)))
  )

  testSync("refuses a shellConfig that names them too", () =>
    expect(
      threw(
        () =>
          ShellConfig.overlay(
            ~bakedManifest=None,
            ~shellConfig=Some(dict{"languages": JSON.Encode.null}),
            ~i18n=declared,
          )->ignore,
      )->Option.isSome,
    )->toBe(true)
  )

  testSync("without catalogues a shellConfig may name the shell's languages", () =>
    expect(
      ShellConfig.overlay(
        ~bakedManifest=None,
        ~shellConfig=Some(dict{"languages": JSON.Encode.string("as given")}),
      )->Dict.get("languages"),
    )->toEqual(Some(JSON.Encode.string("as given")))
  )
})
