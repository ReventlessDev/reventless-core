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

// Create a managed CloudWatch log group with tier retention for a Lambda when the
// stack manages its groups (`Util_LogRetention.managesLogGroup`). The group name
// derives from the function's own *physical* name output — never the logical
// name — so it matches the group Lambda would auto-create and carries Pulumi's
// uniqueness suffix. The caller supplies `~tags` (Logs-role, its own attribution
// convention) and `~opts` (so the group parents to the same component and is torn
// down with it — closing the orphan-group loop for the bespoke builders too). The
// trailing `()` terminates the optional `~opts`.
let makeManagedLogGroup = (
  ~name: string,
  ~lambdaName: Pulumi.Output.t<string>,
  ~tags,
  ~opts=?,
  (),
) => {
  let (stack, prodStacks, unmanagedStacks) = stackContext()
  if Util_LogRetention.managesLogGroup(~stack, ~unmanagedStacks) {
    let days = Util_LogRetention.retentionDaysFor(
      ~stack,
      ~prodStacks,
      ~configOverride=?Util_LocalConfig.get("logRetentionDays")->Option.flatMap(s =>
        Int.fromString(s)
      ),
    )
    let _ = Cloudwatch.LogGroup.make(
      ~name=`${name}LogGroup`,
      ~args={
        name: lambdaName
        ->Pulumi.Output.apply(n => `/aws/lambda/${n}`)
        ->Pulumi.Output.asInput,
        retentionInDays: days->Pulumi.Input.make,
        tags,
      },
      ~opts?,
    )
  }
}
