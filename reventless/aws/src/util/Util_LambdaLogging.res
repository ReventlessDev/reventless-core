// Shared application of the environment-tiered logging policy
// (`Util_LogRetention`) to Lambdas. `RuntimeEnvironment_Lambda.makeFromCodeAsset`
// and the bespoke `Lambda.Function.make` builders (DeadLetterQueue, Upload,
// Geocoder, the platform UI Lambdas, the state-topic publisher) all route the
// `LOG_LEVEL` default and the managed log group through here, so a builder cannot
// silently miss the tier policy — the gap that left ~8 platform Lambdas on the
// logger's default and unmanaged, forever-retained log groups.
open PulumiAws

// Stack + prod allow-list + the unmanaged-groups escape hatch, resolved from
// config. Impure by necessity (reads the stack name and config keys); the tier
// decisions it feeds are the pure functions in `Util_LogRetention`.
let stackContext = () => {
  let stack = Pulumi.Pulumi.getStackName()
  let prodStacks = Util_HostUiDomain.resolveProdStacks()
  let unmanagedStacks = Util_LogRetention.parseUnmanagedStacks(
    Util_LocalConfig.get("unmanagedLogGroupStacks")->Option.getOr(""),
  )
  (stack, prodStacks, unmanagedStacks)
}

// The `("LOG_LEVEL", <tier default>)` env-var entry. For the bespoke builders
// that assemble their env with `Dict.fromArray([...])` and never pin LOG_LEVEL —
// they just append this entry.
let logLevelEntry = (): (string, Pulumi.Input.t<string>) => {
  let (stack, prodStacks, _) = stackContext()
  (
    "LOG_LEVEL",
    Util_LogRetention.logLevelFor(
      ~stack,
      ~prodStacks,
      ~configOverride=?Util_LocalConfig.get("logLevel"),
    )->Pulumi.Input.make,
  )
}

// Default `LOG_LEVEL` to the environment tier when the caller has not pinned one.
// Mutates the given variables dict in place, so it must run after the caller's
// own env vars are set (theirs win). For `makeFromCodeAsset`, whose callers can
// pass LOG_LEVEL through `envVars`.
let applyLogLevelDefault = (variables: dict<Pulumi.Input.t<string>>) =>
  if variables->Dict.get("LOG_LEVEL")->Option.isNone {
    let (key, value) = logLevelEntry()
    variables->Dict.set(key, value)
  }

/** The managed log group name for a Lambda — chosen by the program, never
    derived from the function's physical name output. Two properties follow from
    choosing it:

    - **stable**: it carries no `-<7hex>` Pulumi suffix, so replacing a function
      keeps its group instead of stranding the old one as an orphan nothing
      tears down.
    - **stack-scoped**: stacks sharing an account cannot collide, which was the
      reason the physical name was used before.

    Pure, so the naming is decidable without Pulumi. */
let logGroupNameFor = (~stack: string, ~name: string): string => `/aws/lambda/${stack}-${name}`

// Create the managed CloudWatch log group for a Lambda **before** the function
// that writes to it, so the function can be pointed at it via `loggingConfig`
// (see `loggingConfigFor`) and Lambda never auto-creates a group of its own.
// That ordering is the whole point: a group created *after* its function races
// the auto-create the function's first invocation triggers, and a lost race is
// permanent — the group persists, so every retry fails the same way.
//
// Created when the stack manages its groups (`Util_LogRetention.managesLogGroup`)
// or the caller pins `~retentionDaysOverride` (the app-developer opt-in, which
// wins over the tier default and applies even on an unmanaged stack). `None`
// means the group is left to Lambda, with no retention.
//
// The caller supplies `~tags` (Logs-role, its own attribution convention) and
// `~opts` (so the group parents to the same component and is torn down with it).
// The trailing `()` terminates the optional arguments.
let makeManagedLogGroup = (
  ~name: string,
  ~retentionDaysOverride: option<int>=?,
  ~tags,
  ~opts=?,
  (),
): option<Cloudwatch.LogGroup.t> => {
  let (stack, prodStacks, unmanagedStacks) = stackContext()
  let retentionDays = switch (
    retentionDaysOverride,
    Util_LogRetention.managesLogGroup(~stack, ~unmanagedStacks),
  ) {
  | (Some(days), _) => Some(days)
  | (None, true) =>
    Some(
      Util_LogRetention.retentionDaysFor(
        ~stack,
        ~prodStacks,
        ~configOverride=?Util_LocalConfig.get("logRetentionDays")->Option.flatMap(s =>
          Int.fromString(s)
        ),
      ),
    )
  | (None, false) => None
  }
  retentionDays->Option.map(days =>
    Cloudwatch.LogGroup.make(
      ~name=`${name}LogGroup`,
      ~args={
        name: logGroupNameFor(~stack, ~name)->Pulumi.Input.make,
        retentionInDays: days->Pulumi.Input.make,
        tags,
      },
      ~opts?,
    )
  )
}

// The `loggingConfig` that points a function at the group `makeManagedLogGroup`
// just created. Reading `logGroup.name` is also what orders the two: Pulumi sees
// the function depend on the group, so the group exists first and the function
// has somewhere to write from its very first invocation.
//
// `None` when the group is unmanaged — the function then carries no
// `loggingConfig` at all and keeps Lambda's auto-created group, exactly as
// before. `Text` is AWS's own default format, so no log line changes shape.
let loggingConfigFor = (logGroup: option<Cloudwatch.LogGroup.t>): option<
  Pulumi.Input.t<Lambda.Function.loggingConfig>,
> =>
  logGroup->Option.map(group =>
    (
      {
        logFormat: "Text"->Pulumi.Input.make,
        logGroup: group.name->Pulumi.Output.asInput,
      }: Lambda.Function.loggingConfig
    )->Pulumi.Input.make
  )
