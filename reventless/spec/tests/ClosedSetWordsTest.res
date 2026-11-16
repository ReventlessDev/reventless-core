open JestGlobals

// Each closed set below is held as a variant and turned into text only where a
// file, a structure or a printed line carries it. These pin that text: every
// word reads back as its case and prints as the same word, and a word a set
// keeps without knowing it is written back unchanged.

describe("ComponentKind", () => {
  testSync("prints each kind as its canonical folder name", () =>
    expect(ComponentKind.all->Array.map(ComponentKind.folderName))->toEqual([
      "StateChange",
      "StateView",
      "StateViewStream",
      "Automation",
      "InboundTranslation",
      "OutboundTranslation",
      "Aggregate",
      "ReadModel",
      "ReadModelStream",
      "Task",
      "ExtensionPoint",
      "Extension",
    ])
  )
})

describe("CapabilityNeed", () => {
  let words = ["Geocoding", "Messaging", "IdentityProvider", "Stash"]

  testSync("prints each need as its name", () =>
    expect(CapabilityNeed.all->Array.map(CapabilityNeed.toString))->toEqual(words)
  )

  testSync("reads each word back, and no other", () =>
    expect(
      Array.concat(words, ["geocoding", "Sms"])->Array.map(
        w => CapabilityNeed.fromString(w)->Option.map(CapabilityNeed.toString),
      ),
    )->toEqual([
      Some("Geocoding"),
      Some("Messaging"),
      Some("IdentityProvider"),
      Some("Stash"),
      None,
      None,
    ])
  )
})

describe("Admission", () => {
  testSync("a door's word reads back as the door", () =>
    expect(
      ["start", "complete", "invite", "openRoles", "Start"]->Array.map(
        w => Admission.doorOfName(w)->Option.map(Admission.doorName),
      ),
    )->toEqual([Some("start"), Some("complete"), Some("invite"), Some("openRoles"), None])
  )

  testSync(
    "a structure's strategy decodes, an unknown one is kept, and each encodes as it came",
    () => {
      let words = ["SelfService", "Invitation", "Provisioned", "ByReferral"]
      let decoded =
        words->Array.map(w => JSON.String(w)->S.parseOrThrow(~to=Admission.strategyWordSchema))
      expect(decoded)->toEqual([
        Admission.SelfServiceWord,
        InvitationWord,
        ProvisionedWord,
        OtherStrategy("ByReferral"),
      ])
      expect(
        decoded->Array.map(
          w => w->S.convertOrThrow(~from=Admission.strategyWordSchema, ~to=S.json),
        ),
      )->toEqual(words->Array.map(w => JSON.String(w)))
    },
  )

  testSync("a def with a strategy this build does not know is refused by name", () =>
    expect(Admission.fromDefs([{role: "Shopper", strategy: OtherStrategy("ByReferral")}]))->toEqual(
      Error("Admission: Shopper: ByReferral is not a strategy"),
    )
  )
})

describe("Visibility, ReadConsistency, Trait", () => {
  testSync("print each case as its name", () =>
    expect((
      [Visibility.Public, Internal]->Array.map(Visibility.toString),
      [ReadConsistency.EscalateOnRetry, AlwaysStrong, AlwaysEventual]->Array.map(
        ReadConsistency.toString,
      ),
      [Trait.WritesBack, Observes, SelfContained]->Array.map(Trait.postureToString),
    ))->toEqual((
      ["Public", "Internal"],
      ["EscalateOnRetry", "AlwaysStrong", "AlwaysEventual"],
      ["WritesBack", "Observes", "SelfContained"],
    ))
  )

  testSync(
    "a structure's visibility decodes, an unknown one is kept and encodes as it came",
    () => {
      let words = ["Public", "Internal", "Hidden"]
      let decoded = words->Array.map(w => JSON.String(w)->S.parseOrThrow(~to=Visibility.schema))
      expect(decoded)->toEqual([Visibility.Public, Internal, OtherVisibility("Hidden")])
      expect(decoded->Array.map(Visibility.toString))->toEqual(words)
    },
  )
})

describe("Plugin.commandLevel", () => {
  testSync("reads each word back, and no other", () =>
    expect(
      ["Collection", "Instance", "collection", ""]->Array.map(
        w => Plugin.commandLevelOfWord(w)->Option.map(l => (l :> string)),
      ),
    )->toEqual([Some("Collection"), Some("Instance"), None, None])
  )
})

describe("MessageFormat argument types", () => {
  let words = [
    "number",
    "date",
    "time",
    "spellout",
    "ordinal",
    "duration",
    "plural",
    "selectordinal",
    "select",
  ]

  testSync("ICU's words read back as themselves", () =>
    expect(
      words->Array.map(w => MessageFormat.argTypeOfWord(w)->Option.map(t => (t :> string))),
    )->toEqual(words->Array.map(w => Some(w)))
  )

  testSync("a word ICU does not have is refused by name", () =>
    expect(MessageFormat.parse("{n, currency}"))->toEqual(
      Error(`the argument "n" has an unknown type "currency" (at character 13)`),
    )
  )
})

describe("AnsiStyle.formatOfWord", () => {
  testSync("reads text and json, and no other", () =>
    expect(
      ["text", "json", "JSON", ""]->Array.map(
        w => AnsiStyle.formatOfWord(w)->Option.map(f => (f :> string)),
      ),
    )->toEqual([Some("text"), Some("json"), None, None])
  )
})

describe("Catalogue element kinds", () => {
  testSync("each text reads as its kind and prints back unchanged", () => {
    let texts = [
      "name",
      "plural",
      "count",
      "field.email",
      "state.Deactivated",
      "value.tier.Gold",
      "value.version.v1.2",
      "error.OrderAlreadyPlaced",
      "plugin",
      "role",
      "field.a.b",
      "summary",
      "note.x",
      "value.tier",
      "",
    ]
    let kinds = texts->Array.map(Catalogue.elementKindOfText)
    expect(kinds)->toEqual([
      Catalogue.NameText,
      PluralText,
      CountText,
      FieldText("email"),
      StateText("Deactivated"),
      ValueText({field: "tier", value: "Gold"}),
      ValueText({field: "version", value: "v1.2"}),
      ErrorText("OrderAlreadyPlaced"),
      PluginText,
      RoleText,
      FieldText("a.b"),
      OtherElementText("summary"),
      OtherElementText("note.x"),
      OtherElementText("value.tier"),
      OtherElementText(""),
    ])
    expect(kinds->Array.map(Catalogue.elementKindText))->toEqual(texts)
  })
})

describe("CheckLifecycleModel's report words", () => {
  testSync("severities print in the order a run prints them", () =>
    expect(CheckLifecycleModel.severities->Array.map(s => (s :> string)))->toEqual([
      "Contradicted",
      "Unverified",
      "Undeclared",
      "LevelMismatch",
      "Ambiguous",
    ])
  )

  testSync("an outcome kind prints as its case's name", () =>
    expect(
      [CheckLifecycleModel.EventOutcome, ErrorOutcome, NoEventOutcome]->Array.map(
        k => (k :> string),
      ),
    )->toEqual(["EventOutcome", "ErrorOutcome", "NoEventOutcome"])
  )

  testSync("a derived level prints as its name, and an absent one as empty", () =>
    expect(
      [Some(Plugin.Collection), Some(Instance), None]->Array.map(CheckLifecycleModel.levelText),
    )->toEqual(["Collection", "Instance", ""])
  )
})
