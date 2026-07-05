let componentType = ComponentType.Plugin

type outputs = ReventlessInfra.Plugin.outputs

type t
type component = Component.t<t, outputs, unit>

module type T = {
  type api
  type role
  let make: (
    ~name: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ReventlessInfra.ExtensionPoint.T)>=?,
    ~extensions: array<module(ReventlessInfra.Extension.Blueprint)>=?,
    ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>=?,
    ~readModels: array<
      module(ReventlessInfra.ReadModel.T with type api = api and type role = role),
    >=?,
    ~tasks: array<module(ReventlessInfra.Task.T)>=?,
    ~stateChangeSlices: array<module(ReventlessInfra.StateChangeSlice.T)>=?,
    ~stateViewSlices: array<module(ReventlessInfra.StateViewSlice.T)>=?,
    ~automationSlices: array<module(ReventlessInfra.AutomationSlice.T)>=?,
    ~outboundTranslationSlices: array<module(ReventlessInfra.OutboundTranslationSlice.T)>=?,
    ~inboundTranslationSlices: array<module(ReventlessInfra.InboundTranslationSlice.T)>=?,
    ~systemCallableComponents: array<string>=?,
    ~uiFragments: Reventless.Plugin.uiFragmentManifest=?,
    ~pluginStructure: Reventless.Plugin.pluginStructure=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
  let makeAutoUIManifest: (
    ~remoteEntryUrl: string,
    ~name: string,
    ~pluginStructure: Reventless.Plugin.pluginStructure,
    ~readModelPositions: array<string>=?,
    ~aggregatePositions: array<string>=?,
  ) => Reventless.Plugin.uiFragmentManifest
  let makePluginDefinition: (
    ~name: string,
    ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>=?,
    ~readModels: array<module(ReventlessInfra.ReadModel.T with type api = api and type role = role)>=?,
    ~stateViewSlices: array<module(ReventlessInfra.StateViewSlice.T)>=?,
    ~stateChangeSlices: array<module(ReventlessInfra.StateChangeSlice.T)>=?,
    ~automationSlices: array<module(ReventlessInfra.AutomationSlice.T)>=?,
    ~outboundTranslationSlices: array<module(ReventlessInfra.OutboundTranslationSlice.T)>=?,
    ~inboundTranslationSlices: array<module(ReventlessInfra.InboundTranslationSlice.T)>=?,
    ~extensions: array<module(ReventlessInfra.Extension.Blueprint)>=?,
    ~extensionPoints: array<module(ReventlessInfra.ExtensionPointMapping.Mapping)>=?,
  ) => Reventless.Plugin.pluginStructure
}

let makeId = (name, version) => `${name}@${version}`

// Inverse of `makeId` for the GraphQL boundary. Internally a plugin id is
// `name@version` so the in-memory platform's plugin store can key by it, but
// the platform invariant is one version per plugin at a time — so anything
// crossing into the UI (routes, federation remote name, subscription
// payloads) gets the bare name. If the input has no `@`, returns it as-is.
let name = (id: string): string =>
  id->String.split("@")->Array.get(0)->Option.getOr(id)

// Version segment of a plugin id (`name@version`). Empty string when the id
// carries no `@` (e.g. the synthetic admin plugin id).
let version = (id: string): string =>
  id->String.split("@")->Array.get(1)->Option.getOr("")

// Compare two plugin version strings (e.g. "0.10.0-alpha.73"), newest-first:
// returns 1 when `a` is newer than `b`, -1 when older, 0 when equal. Separators
// (`.`, `-`, `+`) are normalised, then segments compare numerically when both
// sides are numeric and lexically otherwise — enough to pick the latest among
// the monotonically-increasing lerna versions this platform produces. Used by
// the admin manifest resolvers to enforce the one-version-per-plugin invariant
// when more than one version lingers in `Connected` state.
let compareVersions = (a: string, b: string): int => {
  let parts = s => s->String.replaceRegExp(%re("/[-+]/g"), ".")->String.split(".")
  let pa = parts(a)
  let pb = parts(b)
  let len = pa->Array.length > pb->Array.length ? pa->Array.length : pb->Array.length
  let result = ref(0)
  let i = ref(0)
  while result.contents == 0 && i.contents < len {
    let sa = pa->Array.get(i.contents)->Option.getOr("")
    let sb = pb->Array.get(i.contents)->Option.getOr("")
    switch (Int.fromString(sa), Int.fromString(sb)) {
    | (Some(na), Some(nb)) =>
      if na > nb {
        result := 1
      } else if na < nb {
        result := -1
      }
    | _ =>
      if sa > sb {
        result := 1
      } else if sa < sb {
        result := -1
      }
    }
    i := i.contents + 1
  }
  result.contents
}
