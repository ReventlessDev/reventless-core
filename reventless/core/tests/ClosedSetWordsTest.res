open JestGlobals

// Each closed set below is held as a variant and turned into text only where a
// deployment, a published structure or a log line carries it. These pin that
// text: every word reads back as its case and prints as the same word.

describe("ComponentType", () => {
  let words = [
    "Aggregate",
    "Counter",
    "Plugin",
    "Platform",
    "CommandGenerator",
    "CommandTopic",
    "EventCollector",
    "EventLog",
    "EventMapper",
    "EventTopic",
    "ExtensionPoint",
    "Extension",
    "QueryDB",
    "ReadModel",
    "Scheduler",
    "Service",
    "SideEffectHandler",
    "Task",
    "Vpc",
    "Heartbeat",
    "Cloner",
    "DcbEventLog",
    "StateChangeSlice",
    "StateViewSlice",
    "AutomationSlice",
    "OutboundTranslationSlice",
    "InboundTranslationSlice",
  ]

  testSync("prints each kind as the word a deployment carries", () =>
    expect(ComponentType.all->Array.map(ComponentType.toString))->toEqual(words)
  )

  testSync("reads each word back, and no other", () =>
    expect(
      Array.concat(words, ["QueryDb", "Runtime"])->Array.map(
        w => ComponentType.ofString(w)->Option.map(ComponentType.toString),
      ),
    )->toEqual(Array.concat(words->Array.map(w => Some(w)), [None, None]))
  )

  // The short name every physical resource is named with: a second spelling of
  // the query store that is not the kind's word.
  testSync("the query store's short name stays QueryDb", () =>
    expect(ComponentType.QueryDb->ComponentType.toName)->toBe("QueryDb")
  )
})

describe("ResourceAttribution", () => {
  testSync("a role's text is its name, and an other role is its own word", () =>
    expect(
      [
        ResourceAttribution.Role.QueryDb,
        Runtime,
        EventSourceMapping,
        Other("ChangeFeed"),
      ]->Array.map(ResourceAttribution.Role.toString),
    )->toEqual(["QueryDb", "Runtime", "EventSourceMapping", "ChangeFeed"])
  )
})

describe("Plugin_Structure.labelFieldSource", () => {
  testSync("prints each source in lower case", () =>
    expect(
      [Plugin_Structure.Annotation, Convention, Position, Fallback]->Array.map(
        Plugin_Structure.labelFieldSourceToString,
      ),
    )->toEqual(["annotation", "convention", "position", "fallback"])
  )
})

describe("Plugin_BuiltHook.schemaKind", () => {
  testSync("prints each kind as a published schema carries it", () =>
    expect(
      [Plugin_BuiltHook.RecordSchema, VariantSchema, UnknownSchema]->Array.map(k => (k :> string)),
    )->toEqual(["RecordSchema", "VariantSchema", "UnknownSchema"])
  )
})

describe("Logger levels", () => {
  testSync("a level's label is its upper-case word, and reads back exactly", () => {
    expect(Logger.levels->Array.map(Logger.levelLabel))->toEqual(["DEBUG", "INFO", "WARN", "ERROR"])
    expect(
      ["DEBUG", "INFO", "WARN", "ERROR", "warn", "WARNING"]->Array.map(
        w => Logger.levelOfLabel(w)->Option.map(Logger.levelLabel),
      ),
    )->toEqual([Some("DEBUG"), Some("INFO"), Some("WARN"), Some("ERROR"), None, None])
  })

  testSync("a word reads in any case, warning included", () =>
    expect(
      ["debug", "Info", "WARN", "warning", "Error", "trace"]->Array.map(
        w => Logger.levelOfWord(w)->Option.map(Logger.levelLabel),
      ),
    )->toEqual([Some("DEBUG"), Some("INFO"), Some("WARN"), Some("WARN"), Some("ERROR"), None])
  )
})
