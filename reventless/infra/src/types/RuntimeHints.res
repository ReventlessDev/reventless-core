/**
Per-component runtime resource hints, declared once (portably) on the plugin's
composition surface (`plugin.json` `runtime` block) and threaded into each
component's `make` by the plugin deploy loop.

Both fields are optional; an omitted field falls through to the per-kind builder
default. The value is a *logical envelope* (working-set memory / wall-clock),
not a literal cap — each platform adapter maps it to its own resource model
(AWS Lambda `memorySize`/`timeout`, k8s pod `requests`/`limits`, local ignores).

See docs/plans/configurable-component-runtime-resources.md.
*/
type t = {
  memorySize: option<int>,
  timeout: option<int>,
}

/** No hints — every field falls through to the per-kind builder default. */
let empty: t = {memorySize: None, timeout: None}

/**
Resolve a component's memory floor: the per-component override raises the
per-kind default, never lowers it (`Math.Int.max`). An absent override yields
the default unchanged.
*/
let resolveMemory = (hints: option<t>, ~default: int): int =>
  switch hints {
  | Some({memorySize: Some(m)}) => Math.Int.max(default, m)
  | _ => default
  }

/**
Resolve a component's timeout: an explicit per-component timeout replaces the
default (no `max` — a longer default is not inherently safer). An absent
override yields the default unchanged.
*/
let resolveTimeout = (hints: option<t>, ~default: int): int =>
  switch hints {
  | Some({timeout: Some(t)}) => t
  | _ => default
  }
