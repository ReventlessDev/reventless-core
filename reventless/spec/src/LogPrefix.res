/** Plugin-name resolution for log prefixes.

Shared between `ReventlessCore.Logger` (terminal/CloudWatch emit) and
`ReventlessInfra.{ExtensionPoint,Extension}Mapping.compLog` so logs from
either layer carry the same `[PluginName][Comp]` prefix.

Resolution priority for a comp string like `"Kind(Name)"`:
1. The inner name (e.g. `"AddProduct"`) looked up in `componentPluginRegistry`.
2. The ambient `currentPluginName` ref (set by `Plugin_Builder.construct`).
3. Transformations of the inner name, each tried against the registry:
   - strip `@version` suffix (handles `Plugin(Foo@1.2.3)`)
   - strip trailing `Plugin` (handles `CommandTopic(FooPlugin)`)
   - last dot segment (handles `Extension(Catalog.Products.Ordering)`)
   - first dot segment (handles `ExtensionPoint(Catalog.Products)`)
4. Longest registered component name that prefixes the inner name (handles
   kind-suffixed resource names like `EventCollector(CustomersReadModel)`).

`Plugin_Builder` registers every component (and the plugin's self-name) when
constructing a plugin, so all transformation candidates resolve to a
real plugin name. */

// Ambient plugin name. Set inside `Plugin_Builder.Make.construct` so
// synchronous logs during construction carry a `[Name]` prefix.
let currentPluginName: ref<option<string>> = ref(None)

// Registry: component name → owning plugin name. Populated at construct time.
let componentPluginRegistry: ref<dict<string>> = ref(Dict.make())

let registerComponentPlugin = (~componentName: string, ~pluginName: string) =>
  componentPluginRegistry.contents->Dict.set(componentName, pluginName)

// Stable hash for picking a color from the palette.
let hashStr = (s: string): int => {
  let h = ref(0)
  for i in 0 to s->String.length - 1 {
    let code = s->String.charCodeAt(i)->Option.getOr(0)
    h := h.contents + code * (i + 1)
  }
  h.contents
}

// Foreground colors that don't collide with level indicators (cyan / yellow / red).
let pluginColors = [
  "\x1b[32m", // green
  "\x1b[34m", // blue
  "\x1b[35m", // magenta
  "\x1b[92m", // bright green
  "\x1b[94m", // bright blue
  "\x1b[95m", // bright magenta
]

let pluginColor = (name: string): string =>
  pluginColors->Array.getUnsafe(mod(hashStr(name), pluginColors->Array.length))

// Extract the inner argument from a comp like `"Kind(Name)"`.
let extractInnerName = (comp: string): option<string> => {
  let openIdx = comp->String.indexOf("(")
  let closeIdx = comp->String.lastIndexOf(")")
  if openIdx > 0 && closeIdx > openIdx + 1 {
    Some(comp->String.slice(~start=openIdx + 1, ~end=closeIdx))
  } else {
    None
  }
}

let stripAtVersion = (s: string): option<string> => {
  let idx = s->String.indexOf("@")
  if idx > 0 {
    Some(s->String.slice(~start=0, ~end=idx))
  } else {
    None
  }
}

let stripPluginSuffix = (s: string): option<string> => {
  let suffix = "Plugin"
  if s->String.endsWith(suffix) && s->String.length > suffix->String.length {
    Some(s->String.slice(~start=0, ~end=s->String.length - suffix->String.length))
  } else {
    None
  }
}

let firstDotSegment = (s: string): option<string> => {
  let idx = s->String.indexOf(".")
  if idx > 0 {
    Some(s->String.slice(~start=0, ~end=idx))
  } else {
    None
  }
}

let lastDotSegment = (s: string): option<string> => {
  let idx = s->String.lastIndexOf(".")
  if idx > 0 && idx + 1 < s->String.length {
    Some(s->String.slice(~start=idx + 1, ~end=s->String.length))
  } else {
    None
  }
}

let lookup = (name: string): option<string> =>
  componentPluginRegistry.contents->Dict.get(name)

// Last-resort candidate: the inner name is a registered component name carrying a
// component-kind suffix (`Customers` + `ReadModel` → `CustomersReadModel`), which is
// how event-collector resources are named. Longest prefix wins so `OrdersReadModel`
// resolves via `Orders` rather than a shorter `Order` registered by another plugin.
// LogPrefix sits below `ComponentType`, so this stays suffix-table-free.
let longestRegisteredPrefix = (name: string): option<string> =>
  componentPluginRegistry.contents
  ->Dict.keysToArray
  ->Array.reduce(None, (acc, key) =>
    if key->String.length < name->String.length && name->String.startsWith(key) {
      switch acc {
      | Some(best) if best->String.length >= key->String.length => acc
      | _ => Some(key)
      }
    } else {
      acc
    }
  )
  ->Option.flatMap(lookup)

let resolvePlugin = (~comp=?, ()) =>
  switch comp {
  | Some(c) =>
    switch extractInnerName(c) {
    | Some(inner) =>
      switch lookup(inner) {
      | Some(p) => Some(p)
      | None =>
        switch currentPluginName.contents {
        | Some(p) => Some(p)
        | None =>
          // Try transformations in declaration order; first hit wins.
          let candidates = [
            stripAtVersion(inner),
            stripPluginSuffix(inner),
            lastDotSegment(inner),
            firstDotSegment(inner),
          ]
          candidates
          ->Array.reduce(None, (acc, candidate) =>
            switch acc {
            | Some(_) => acc
            | None => candidate->Option.flatMap(lookup)
            }
          )
          ->Option.orElse(longestRegisteredPrefix(inner))
        }
      }
    | None => currentPluginName.contents
    }
  | None => currentPluginName.contents
  }

// Plain (no ANSI) prefix used for Lambda/CloudWatch output.
let fmtPlainPrefix = (~comp=?, ()) => {
  let plugin = switch resolvePlugin(~comp?, ()) {
  | Some(p) => `[${p}]`
  | None => ""
  }
  let c = switch comp {
  | Some(c) => `[${c}] `
  | None => ""
  }
  plugin ++ c
}

// Bold-bracketed prefix used for terminal output.
// Plugin bracket is colored (foreground) by a stable hash of the plugin name;
// no trailing space between `[Plugin]` and `[Comp]`.
//
// Sink-aware: in a non-TTY/JSON sink it falls back to `fmtPlainPrefix` so no
// ANSI colour or bold leaks into structured logs. This makes every caller that
// pre-formats a prefix before reaching `Logger.emit` (EffectLogger.withComp,
// the infra-layer `compLog`s) correct without per-call-site changes.
let fmtComp = (~comp=?, ()) =>
  if !AnsiStyle.useAnsi() {
    fmtPlainPrefix(~comp?, ())
  } else {
    let plugin = switch resolvePlugin(~comp?, ()) {
    | Some(p) => `${pluginColor(p)}${AnsiStyle.bold(`[${p}]`)}`
    | None => ""
    }
    let c = switch comp {
    | Some(c) => `${AnsiStyle.bold(`[${c}]`)} `
    | None => ""
    }
    plugin ++ c
  }
