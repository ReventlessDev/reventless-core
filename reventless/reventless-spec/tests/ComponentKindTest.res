// Pins `ComponentKind` — the single-source component-kind vocabulary (plan C2)
// the plugin generator (`Discovery`) and the gwt graph tooling (`ComponentMeta`)
// both derive from. The bug C2 fixed was the gwt side recognising only singular
// folder names while the generator accepted plural / short spellings; these
// cases lock in that every accepted spelling maps to the SAME canonical kind so
// the two can't silently drift apart again.

open JestGlobals

module K = ComponentKind

describe("ComponentKind.folderToKind", () => {
  // Each row: the canonical, plural, and (for slices) short spellings that must
  // all resolve to the one kind.
  let spellings: array<(K.t, array<string>)> = [
    (StateChangeSlice, ["StateChangeSlice", "StateChangeSlices", "StateChange", "StateChanges"]),
    (StateViewSlice, ["StateViewSlice", "StateViewSlices", "StateView", "StateViews"]),
    (StateViewSliceStream, ["StateViewSliceStream", "StateViewSliceStreams"]),
    (AutomationSlice, ["AutomationSlice", "AutomationSlices", "Automation", "Automations"]),
    (
      InboundTranslationSlice,
      [
        "InboundTranslationSlice",
        "InboundTranslationSlices",
        "InboundTranslation",
        "InboundTranslations",
      ],
    ),
    (
      OutboundTranslationSlice,
      [
        "OutboundTranslationSlice",
        "OutboundTranslationSlices",
        "OutboundTranslation",
        "OutboundTranslations",
      ],
    ),
    (Aggregate, ["Aggregate", "Aggregates"]),
    (ReadModel, ["ReadModel", "ReadModels"]),
    (ReadModelStream, ["ReadModelStream", "ReadModelStreams"]),
    (Task, ["Task", "Tasks"]),
    (ExtensionPoint, ["ExtensionPoint", "ExtensionPoints"]),
    (Extension, ["Extension", "Extensions"]),
  ]

  spellings->Array.forEach(((kind, folders)) =>
    folders->Array.forEach(folder =>
      testSync(`${folder} -> ${K.folderName(kind)}`, () =>
        expect(K.folderToKind(folder))->toEqual(Some(kind))
      )
    )
  )

  testSync("every kind's canonical folderName round-trips back to itself", () =>
    K.all->Array.forEach(kind =>
      expect(K.folderToKind(K.folderName(kind)))->toEqual(Some(kind))
    )
  )

  testSync("a non-kind folder is None", () => expect(K.folderToKind("Helpers"))->toEqual(None))

  testSync("the empty string is not a kind folder", () =>
    expect(K.isKindFolder(""))->toEqual(false)
  )

  testSync("a plural spelling is still recognised as a kind folder", () =>
    expect(K.isKindFolder("Aggregates"))->toEqual(true)
  )
})
