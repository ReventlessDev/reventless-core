// Deploy-time check on a Lambda's environment size.
//
// AWS caps the whole environment of a function at 4096 bytes and rejects the
// UpdateFunctionConfiguration call that exceeds it. That rejection lands in the
// middle of a `pulumi up`, after the surrounding resources have already moved,
// so the stack is left half-updated and the message names a byte count rather
// than the field that grew. This has now bitten three times: `pluginDefinition`
// inline in HANDLER_CONFIG, the DCB slice registry, and the EventCollector's
// publishToAggregates map plus the PTA_ vars it names.
//
// The check runs where HANDLER_CONFIG is still a plain string — inside the
// builders' `Pulumi.Output.apply` — because that is the last point anything is
// measurable. By the time the env reaches `RuntimeEnvironment_Lambda`, the big
// values are Outputs, and totalling them there would mean a bulk resolve of the
// very dict `PluginRuntime_Builder` documents as unsafe to resolve in bulk.
//
// So the total is part exact, part estimated:
//   * exact    — the fixed framework vars, HANDLER_CONFIG, and every env var NAME
//   * estimated — one allowance per Output-valued env var, since the value (an SQS
//                 URL) is not resolved yet
//
// Exceeding the limit on the exact part alone is a certainty, and fails the
// deploy. Exceeding it only once the allowances are added is a likelihood, and
// warns: a wrong estimate must not block a deploy that would have succeeded.

let limit = 4096

// Environment, NODE_OPTIONS, ESM_FALLBACK_DIRS, LOG_LEVEL,
// REVENTLESS_ELEVATED_GROUPS — set for every Lambda by RuntimeEnvironment_Lambda.
let frameworkVarsBytes = 191

// An SQS queue URL: https://sqs.<region>.amazonaws.com/<account>/<name>[.fifo].
// Rounded up from the longest in the example platforms, so the estimate errs
// toward warning early rather than reporting a limit breach as headroom.
let outputValueAllowance = 100

let log = ReventlessCore.Logger.fromEnv()

/**
 * Check one Lambda's environment against the 4KB limit.
 *
 * `~outputValuedKeys` are env vars whose value is still an unresolved Output —
 * counted by name plus `outputValueAllowance`. Raises when the exact portion
 * alone is over the limit; warns when only the estimate is.
 */
let check = (
  ~lambdaName: string,
  ~handlerConfigJson: string,
  ~outputValuedKeys: array<string>=[],
) => {
  let handlerConfigBytes = String.length("HANDLER_CONFIG") + String.length(handlerConfigJson)
  let keyBytes = outputValuedKeys->Array.reduce(0, (acc, k) => acc + String.length(k))
  let exact = frameworkVarsBytes + handlerConfigBytes + keyBytes
  let estimated = exact + outputValuedKeys->Array.length * outputValueAllowance

  if exact > limit {
    JsError.throwWithMessage(
      `${lambdaName}: Lambda environment is ${exact->Int.toString} bytes before the ` ++
      `${outputValuedKeys->Array.length->Int.toString} queue-URL vars are resolved, over the ` ++
      `${limit->Int.toString}-byte limit. HANDLER_CONFIG is ${handlerConfigBytes->Int.toString} ` ++
      `bytes of it — move the term that grows with the plugin into a code-archive asset ` ++
      `(Util_Bundle.buildCodeArchive ~extraStringAssets), as pluginDefinition.json and ` ++
      `sliceModules.json already are.`,
    )
  } else if estimated > limit {
    log.warn(
      ~comp="Util_LambdaEnvBudget",
      `${lambdaName}: Lambda environment is about ${estimated->Int.toString} bytes ` ++
      `(${exact->Int.toString} exact + ${outputValuedKeys->Array.length->Int.toString} queue-URL ` ++
      `vars), at or over the ${limit->Int.toString}-byte limit. The deploy may fail on ` ++
      `UpdateFunctionConfiguration; move a plugin-sized term out of HANDLER_CONFIG.`,
    )
  }
}
