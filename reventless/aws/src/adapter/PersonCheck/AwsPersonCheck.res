// A deployed function's person check: Cloudflare Turnstile, with the secret the
// stack sets (`platform:personCheckSecret`). Unset, the check cannot be asked and
// every sign-up is refused; the deploy refuses a self-service role before that.
//
// A check that cannot be asked is logged as a metric line, which the deployment's
// alarm counts: the door is refusing every visitor, and someone has to hear of it.
//
// Runtime-pure: no Pulumi, bundled into the command function.

/** The metric line's name, which the deploy's metric filter and alarm read. */
let metricName = "PersonCheckUnavailable"

/** The metric line's `slice`, the dimension the filter reads: the check, whatever
    door asked it. */
let metricSlice = "PersonCheck"

let log = ReventlessCore.Logger.fromEnv()

/** `check`, with every `Unavailable` it answers logged and counted. */
let counted = (check: Reventless.PersonCheck.t): Reventless.PersonCheck.t => {
  verify: async (~token) =>
    switch await check.verify(~token) {
    | Error(Unavailable(why)) as failed =>
      Console.log(
        JSON.stringifyAny({
          "reventlessMetric": metricName,
          "slice": metricSlice,
          "value": 1,
        })->Option.getOr(""),
      )
      log.error(~comp="PersonCheck", `the person check cannot be asked: ${why}`)
      failed
    | answer => answer
    },
}

/** The check, given its secret as handed: Turnstile with it, and without it a
    check that cannot be asked. */
let fromSecret = (
  secret: option<string>,
  ~post: PersonCheck_Turnstile.post=PersonCheck_Turnstile.fetchPost,
): Reventless.PersonCheck.t =>
  counted(
    switch secret->Option.map(String.trim) {
    | None | Some("") => Reventless.Capabilities.none.personCheck
    | Some(secret) => PersonCheck_Turnstile.provider(~secret, ~post)
    },
  )

/** The function's check, read per call like the other door settings. */
let fromEnv = (): Reventless.PersonCheck.t =>
  fromSecret(NodeProcess.env->Dict.get(Reventless.PersonCheck.secretEnvKey))
