open JestGlobals

// A catalogue's text formatted for a reader, by the parser `generate-catalogue check` reads it with.

let render = (~locale="en", ~values=Dict.make(), text) =>
  switch MessageFormat.parse(text) {
  | Ok(message) => message->MessageFormat.format(~locale, ~values)
  | Error(reason) => `parse error: ${reason}`
  }

describe("MessageFormat.format", () => {
  testSync("fills arguments, and writes a missing one as it stands", () =>
    expect((
      render("Hello {name}", ~values=dict{"name": MessageFormat.Text("Ada")}),
      render("Hello {name}"),
    ))->toEqual(("Hello Ada", "Hello {name}"))
  )

  testSync("picks the plural case the language's rule names, with # as the number", () => {
    let text = "{count, plural, =0 {no orders} one {# order} other {# orders}}"
    expect(
      [0.0, 1.0, 5.0]->Array.map(n => render(text, ~values=dict{"count": Number(n)})),
    )->toEqual(["no orders", "1 order", "5 orders"])
  })

  testSync("writes # in the language's digits and separators", () =>
    expect(
      render(
        ~locale="de",
        "{count, plural, one {# Bestellung} other {# Bestellungen}}",
        ~values=dict{"count": Number(1234.0)},
      ),
    )->toEqual("1.234 Bestellungen")
  )

  testSync("selects a case, else other", () => {
    let text = "{kind, select, invited {an invitation} other {a code}}"
    expect((
      render(text, ~values=dict{"kind": Text("invited")}),
      render(text, ~values=dict{"kind": Text("anything")}),
    ))->toEqual(("an invitation", "a code"))
  })

  testSync("unquotes literal braces and doubled apostrophes", () =>
    expect(
      render("Use '{name}' literally, it''s {real}", ~values=dict{"real": Text("so")}),
    )->toEqual("Use {name} literally, it's so")
  )

  testSync("writes a duration and a list as the language does", () =>
    expect((
      render("{d} for {who}", ~values=dict{"d": Duration(86400 + 3600), "who": List(["A", "B"])}),
      render(
        ~locale="de",
        "{d} für {who}",
        ~values=dict{"d": Duration(7 * 86400), "who": List(["A", "B"])},
      ),
    ))->toEqual(("1 day and 1 hour for A and B", "7 Tage für A und B"))
  )

  testSync("names the same placeholders the check compares", () =>
    expect(
      MessageFormat.placeholders("{n, plural, one {# by {who}} other {# by {who} and {more}}}"),
    )->toEqual(Ok(["more", "n", "who"]))
  )
})

describe("Text.format", () => {
  let hello: Text.message = {key: "app.hello", source: "Hello {name}"}
  let values = dict{"name": MessageFormat.Text("Ada")}
  let text = Text.fromCatalogues(
    ~default="de",
    dict{
      "de": dict{"app.hello": "Hallo {name}"},
      "de-x-du": dict{},
      "fr": dict{"app.hello": "Bonjour {name"},
    },
  )

  test(
    "takes the language asked for, then its base, then the default, then the English",
    async () => {
      let inLanguage = async language =>
        switch await text->Text.format(hello, ~language, ~values) {
        | Ok({language, text}) => (language, text)
        | Error(reason) => ("error", reason)
        }
      expect((
        await inLanguage("de"),
        await inLanguage("de-x-du"),
        await inLanguage("fr"),
        await Text.sourceOnly
        ->Text.format(hello, ~language="de", ~values)
        ->Promise.thenResolve(r => r->Result.map(t => (t.language, t.text))),
      ))->toEqual((
        ("de", "Hallo Ada"),
        ("de", "Hallo Ada"),
        ("de", "Hallo Ada"),
        Ok(("en", "Hello Ada")),
      ))
    },
  )

  test("a catalogue that cannot be read is an error, not another language", async () => {
    let unreadable = {...text, catalogue: async _ => Error("unreachable")}
    expect(await unreadable->Text.format(hello, ~language="de", ~values))->toEqual(
      Error("unreachable"),
    )
  })

  test("compose labels the message with its body's language", async () => {
    let composed = await text->Text.compose(
      ~recipient=ToEmail(Email.unsafe("ada@example.com")),
      ~subject={key: "app.subject", source: "Greetings"},
      ~body=hello,
      ~values,
    )
    expect(composed)->toEqual(
      Ok({Messaging.subject: "Greetings", body: "Hallo Ada", language: "de"}),
    )
  })
})

describe("Template with a locale", () => {
  testSync("writes a duration in words; without a locale, as before", () => {
    let schema = S.object(s => s.field("ttl", Duration.schema))
    let payload = JSON.parseOrThrow(`{"ttl": 7200}`)
    expect((
      Template.renderSource("{{ ttl }}", ~payload, ~schema, ~locale="de"),
      Template.renderSource("{{ ttl }}", ~payload, ~schema),
    ))->toEqual((Ok("2 Stunden"), Ok("2h")))
  })
})
