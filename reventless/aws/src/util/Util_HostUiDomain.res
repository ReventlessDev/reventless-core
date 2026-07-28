// FQDN derivation for the host-UI shell's custom domain. Pure function so it
// can be unit-tested without touching Pulumi / `Util_LocalConfig`. Convention:
//
//   stack ∈ prodStacks → "${baseName}.${baseDomain}"
//   otherwise         → "${baseName}-${stack}.${baseDomain}"
//
// `prodStacks` defaults to `["prod", "main"]` and is overridable via the
// `hostUiProdStacks` config key (CSV) for teams using `production`, `live`,
// etc. The `baseName` defaults to `Pulumi.getProjectName()` and can be
// overridden per-stack via `hostUiBaseName` — useful when the Pulumi project
// name is longer than what looks good in a URL.

let defaultProdStacks = ["prod", "main"]

/** Pure FQDN derivation. */
let deriveFqdn = (~baseName: string, ~stack: string, ~baseDomain: string, ~prodStacks: array<string>): string =>
  prodStacks->Array.includes(stack)
    ? `${baseName}.${baseDomain}`
    : `${baseName}-${stack}.${baseDomain}`

/** Parse a CSV-encoded prod-stacks override. Empty entries are dropped so a
   trailing comma or leading/trailing whitespace doesn't smuggle in a phantom
   stack name. */
let parseProdStacks = (csv: string): array<string> =>
  csv
  ->String.split(",")
  ->Array.map(String.trim)
  ->Array.filter(s => s !== "")

/**
The stacks this deployment considers production, resolved from config.

The one notion of "is this stack production", deliberately shared rather than
answered twice. Domain naming asked it first; object-store layout asks it too,
and a second key would be two flags that can disagree — the state where a stack
gets a production domain and non-production storage, or the reverse, with
nothing to flag the mismatch.

Impure by necessity (it reads config); the derivations that consume it stay
pure and unit-tested.
*/
let resolveProdStacks = (): array<string> =>
  Util_LocalConfig.get("hostUiProdStacks")
  ->Option.map(parseProdStacks)
  ->Option.getOr(defaultProdStacks)
