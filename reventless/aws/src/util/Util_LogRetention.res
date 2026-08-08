// How long a stack keeps its logs, and how verbose they are — tiered by
// environment, the same way `Util_StoreLayout` tiers bucket layout and
// `Util_HostUiDomain` tiers the host-shell FQDN. Pure functions so both
// decisions are decidable and unit-testable without touching Pulumi.
//
// Retention and level pull in opposite directions between prod and dev, which is
// the whole reason a single global setting cannot serve both:
//
//   prod  — quiet (`info`) and long-lived (365d): incident + forensic window
//   dev   — loud  (`debug`) and short-lived (3–7d): consumed within hours
//
// The `prodStacks` allow-list is `Util_HostUiDomain.resolveProdStacks` — the one
// notion of "is this stack production" the platform already shares for domain
// naming and store layout, on purpose. A `configOverride` (from the Pulumi
// `logRetentionDays` / `logLevel` config keys) wins over the tier default so a
// stack can be dialled without a code change.

// CloudWatch only accepts a fixed enum of retention values; every number below is
// a member of it. `0` means "never expire" and is a valid explicit opt-in, but
// never a tier default — hot CloudWatch storage billed forever is what this
// tiering exists to bound.

/** Retention in days for a stack. prod/main = 365, beta = 30, `pr-*` = 3,
    everything else (alpha and any unlisted stack) = 7. A `configOverride` wins. */
let retentionDaysFor = (
  ~stack: string,
  ~prodStacks: array<string>,
  ~configOverride: option<int>=?,
): int =>
  switch configOverride {
  | Some(days) => days
  | None =>
    switch stack {
    | s if prodStacks->Array.includes(s) => 365
    | "beta" => 30
    | s if s->String.startsWith("pr-") => 3
    | _ => 7
    }
  }

/** The default `LOG_LEVEL` for a stack. prod/main and beta stay at `info` so
    pre-prod behaves like prod and debug detail never leaks payloads in prod;
    every other stack defaults to `debug` for verbose feedback during active
    development (paired with short retention, so cheap). A `configOverride`
    wins. */
let logLevelFor = (
  ~stack: string,
  ~prodStacks: array<string>,
  ~configOverride: option<string>=?,
): string =>
  switch configOverride {
  | Some(level) => level
  | None =>
    switch stack {
    | s if prodStacks->Array.includes(s) => "info"
    | "beta" => "info"
    | _ => "debug"
    }
  }

/**
Whether the framework creates a *managed* CloudWatch log group for this stack, or
leaves Lambda/AppSync to auto-create an unmanaged one.

**Managed for every stack by default**, and for Lambda there is nothing to adopt
on any stack: the group is created *before* the function and under a name the
program chooses (`Util_LambdaLogging.logGroupNameFor`), which is never the name
Lambda auto-creates. The `ResourceAlreadyExists` hazard that made this gate
necessary is structural for AppSync only, whose group name comes from a
server-assigned api id.

`unmanagedLogGroupStacks` remains the escape hatch for a stack that has adopted
**nothing** — it makes the program stop *declaring* log groups. Do not reach for
it once a stack holds managed groups in state: "stop declaring them" reads to the
engine as removed-from-the-program, and the next deploy deletes them along with
their retention, tags and any attached metric filters.
*/
let managesLogGroup = (~stack: string, ~unmanagedStacks: array<string>=[]): bool =>
  !(unmanagedStacks->Array.includes(stack))

/** Parse the `unmanagedLogGroupStacks` config value — a CSV of stack names kept
    on auto-created groups pending a `pulumi import`. Same tolerant parse as the
    prod-stacks list: trims, drops empty entries. */
let parseUnmanagedStacks = (csv: string): array<string> =>
  csv->String.split(",")->Array.map(String.trim)->Array.filter(s => s !== "")
