// Single source of truth for the Reventless component-kind vocabulary: the kinds
// themselves, every accepted folder spelling (singular / plural / short form),
// the canonical folder name, and the body-file suffixes. The plugin generator
// (`generator/Discovery`) and the external tooling that classifies files by
// folder (`reventless-gwt`'s `ComponentMeta`) both derive from this, so the two
// can't drift — previously the generator accepted plural/short folder names that
// the gwt discovery silently didn't recognize.

// A slice's folder drops the `Slice` the kind carries: the folder already sits
// inside a plugin's `src/`, so the suffix only lengthened every path. Each case's
// text is its canonical (singular) folder name, the spelling the naming
// conventions and the graph `kind` field use.
type t =
  | @as("StateChange") StateChangeSlice
  | @as("StateView") StateViewSlice
  | @as("StateViewStream") StateViewSliceStream
  | @as("Automation") AutomationSlice
  | @as("InboundTranslation") InboundTranslationSlice
  | @as("OutboundTranslation") OutboundTranslationSlice
  | Aggregate
  | ReadModel
  | ReadModelStream
  | Task
  | ExtensionPoint
  | Extension

let all = [
  StateChangeSlice,
  StateViewSlice,
  StateViewSliceStream,
  AutomationSlice,
  InboundTranslationSlice,
  OutboundTranslationSlice,
  Aggregate,
  ReadModel,
  ReadModelStream,
  Task,
  ExtensionPoint,
  Extension,
]

// The canonical (singular) folder name for a kind. The suffixed spellings stay
// accepted by `folderToKind` below.
let folderName = (t: t): string => (t :> string)

// Every folder spelling that denotes a kind → the kind. Tolerates the singular,
// plural, and (for slices) short forms the generator has always accepted.
let folderToKind = (folder: string): option<t> =>
  switch folder {
  | "StateChange" | "StateChanges" | "StateChangeSlice" | "StateChangeSlices" =>
    Some(StateChangeSlice)
  | "StateView" | "StateViews" | "StateViewSlice" | "StateViewSlices" => Some(StateViewSlice)
  | "StateViewStream"
  | "StateViewStreams"
  | "StateViewSliceStream"
  | "StateViewSliceStreams" =>
    Some(StateViewSliceStream)
  | "Automation" | "Automations" | "AutomationSlice" | "AutomationSlices" => Some(AutomationSlice)
  | "InboundTranslation"
  | "InboundTranslations"
  | "InboundTranslationSlice"
  | "InboundTranslationSlices" =>
    Some(InboundTranslationSlice)
  | "OutboundTranslation"
  | "OutboundTranslations"
  | "OutboundTranslationSlice"
  | "OutboundTranslationSlices" =>
    Some(OutboundTranslationSlice)
  | "Aggregate" | "Aggregates" => Some(Aggregate)
  | "ReadModel" | "ReadModels" => Some(ReadModel)
  | "ReadModelStream" | "ReadModelStreams" => Some(ReadModelStream)
  | "Task" | "Tasks" => Some(Task)
  | "ExtensionPoint" | "ExtensionPoints" => Some(ExtensionPoint)
  | "Extension" | "Extensions" => Some(Extension)
  | _ => None
  }

let isKindFolder = (folder: string): bool => folderToKind(folder)->Option.isSome

// Body-file suffixes stripped to recover a component's spec stem (longest first,
// so `_ExtensionPointMapping` is removed before `_ExtensionPoint`). Spec and body
// files in one folder collapse to the same component name.
let bodySuffixes = [
  "_ExtensionPointMapping",
  "_ExtensionPoint",
  "_Extension",
  "_Projections",
  "_Projection",
  "_Mappings",
  "_Decision",
  "_Automation",
  "_Translation",
]
