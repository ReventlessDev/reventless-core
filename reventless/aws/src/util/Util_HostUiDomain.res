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
