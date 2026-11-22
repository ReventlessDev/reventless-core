// The mail guards: registration mail stops for the day at its cap, refused rather
// than retried, with a metric line the alarm counts; only the senders marked as
// mailing visitors are capped; and the platform's settings for the operator and
// the budget are refused when mistyped.

open JestGlobals

module Cap = Messaging_DailyCap

let sent = []
let provider: Reventless.Messaging.provider = {
  channels: [Email],
  pushServices: [],
  send: async (~recipient as _, ~message) => {
    sent->Array.push(message.body)
    Ok({ref: "m-1"})
  },
}

let to = Reventless.Messaging.ToEmail(Reventless.Email.unsafe("ada@example.com"))

describe("the daily cap on registration mail", () => {
  testPromise("sends while the day allows, then refuses without retrying", async () => {
    let left = ref(1)
    let capped = Cap.capped(
      provider,
      ~allow=async () => {
        left := left.contents - 1
        left.contents >= 0
      },
      ~slice="SendRegistrationChallenge",
    )
    let first = await capped.send(~recipient=to, ~message={body: "code 1", subject: "Your code"})
    let second = await capped.send(~recipient=to, ~message={body: "code 2", subject: "Your code"})
    expect((
      first,
      second->Result.mapError(Reventless.Messaging.retriable),
      sent->Array.includes("code 2"),
    ))->toEqual((Ok({Reventless.Messaging.ref: "m-1"}), Error(false), false))
  })

  testSync("the cap is a positive count, and anything else is refused", () =>
    expect((
      Cap.parseCap(" 20 "),
      Cap.parseCap("0")->Result.isError,
      Cap.parseCap("lots")->Result.isError,
    ))->toEqual((Ok(20), true, true))
  )

  testSync("only a slice marked as mailing visitors is capped", () => {
    let before = NodeProcess.env->Dict.get(Cap.slicesVariable)
    NodeProcess.env->Dict.set(Cap.slicesVariable, "SendRegistrationChallenge, ")
    let capabilities = Reventless.Capabilities.none
    let marked = Cap.forSlice(capabilities, ~slice="SendRegistrationChallenge")
    let other = Cap.forSlice(capabilities, ~slice="SendInvoice")
    switch before {
    | Some(v) => NodeProcess.env->Dict.set(Cap.slicesVariable, v)
    | None => NodeProcess.env->Dict.delete(Cap.slicesVariable)
    }
    expect((Cap.cappedSlices(), marked === capabilities, other === capabilities))->toEqual((
      before->Option.mapOr([], _ => Cap.cappedSlices()),
      false,
      true,
    ))
  })

  testSync("the senders are read off the plugin's marks", () => {
    let structure: Reventless.Plugin.pluginStructure = {
      readModels: [],
      stateViewSlices: [],
      stateChangeSlices: [],
      aggregates: [],
      automationSlices: [],
      outboundTranslationSlices: [],
      inboundTranslationSlices: [],
      extensions: [],
      admissionDoors: [
        {Reventless.Admission.component: "SignUp", part: "start"},
        {Reventless.Admission.component: "SendRegistrationChallenge", part: "mail"},
      ],
    }
    expect((
      AutomationMailCap.mailSlices(Some(structure)),
      AutomationMailCap.mailSlices(None),
    ))->toEqual((["SendRegistrationChallenge"], []))
  })
})

describe("the platform's settings for its operator", () => {
  testSync("an operator address must be one", () =>
    expect((
      Platform_Guards.parseOperatorAddress(Some(" ops@example.com ")),
      Platform_Guards.parseOperatorAddress(None),
      Platform_Guards.parseOperatorAddress(Some("ops"))->Result.isError,
    ))->toEqual((Ok(Some("ops@example.com")), Ok(None), true))
  )

  testSync("the budget is whole dollars, twenty when unset", () =>
    expect((
      Platform_Guards.parseMonthlyUsd(None),
      Platform_Guards.parseMonthlyUsd(Some("75")),
      Platform_Guards.parseMonthlyUsd(Some("7.5"))->Result.isError,
      Platform_Guards.parseMonthlyUsd(Some("-1"))->Result.isError,
    ))->toEqual((Ok(20), Ok(75), true, true))
  )

  testSync("the configuration set is named for the stack, as SES accepts names", () =>
    expect(Platform_Guards.configurationSetName(~project="amperia.platform", ~stack="dev"))->toBe(
      "amperia-platform-dev",
    )
  )

  testSync("with the sender and the alarm, only the person check is still missing", () =>
    expect(
      AppSync_VisitorGuards.missing({
        fingerprintKey: true,
        personCheck: false,
        boundedSender: true,
        billAlarm: true,
      }),
    )->toEqual([AppSync_VisitorGuards.PersonCheck])
  )
})
