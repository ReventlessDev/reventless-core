@@reventless.spec("PluginHistory")

// Rich audit view — the full per-version lifecycle timeline (analysis §6.2).
// One row per *transition*: partition key = plugin **name** (the aggregate id),
// sort key = `version#transitionAt#transition`. A faithful fold of the Plugin
// aggregate's event stream — zero inference. Surfaced as a Public admin read
// model (declared in `Platform_Admin_Structure` + `PluginBaseFragment`, resolver
// via `ReadModel_Builder_Single_Stream`), so the AutoUI renders the plugin
// lifecycle timeline — every version in every state (Connected / Disconnected /
// Superseded / Inactive / Retired) plus the transition history.

// Each lifecycle transition recorded in the audit trail. `Superseded` and
// `Promoted` are first-class here (decided write-side, §6.2.3) — the current
// view derives "superseded" instead, but history keeps the explicit edge.
@schema
type transition =
  | Detected
  | Connected
  | Superseded
  | Promoted
  | Disconnected
  | Activated
  | Deactivated
  | Retired
  | IncompatibleDetected

@schema
type state = {
  name: Reventless.Plugin.name,
  // The version this transition is about. For `Superseded` it is the *new*
  // (superseding) version; `supersededVersion` carries the one taken over.
  version: Reventless.Plugin.version,
  // Sort key. `version#transitionAt#transition` orders the timeline per name and
  // uniquely identifies each transition (one transition kind per version per ms).
  transitionKey: string,
  transition: transition,
  // Producer time (meta.time) of the event that recorded this transition.
  transitionAt: string,
  // Actor who initiated it (meta.user), or "" for system-driven transitions.
  by: string,
  // Set only on `Superseded` rows: the version that was taken over.
  supersededVersion?: Reventless.Plugin.version,
}

// Manual config + subIdConfig (the `*ReadModelSpec` PPX only auto-injects these
// when no `let config` is present, and always with `subIdConfig = None`). This is
// a composite-key (timeline) read model, so the sub-id is the sort key.
let config = Reventless.ReadModel.config()
let subIdConfig = Some({
  Reventless.ReadModel.subIdField: "transitionKey",
  getSubId: (s: state) => s.transitionKey,
})
