open JestGlobals

// Which transport a stack mails through, and who it sends as. There is no
// default address: a placeholder would provision an identity nobody can verify,
// so "unset" has to survive the whole way to the deploy gate as absence rather
// than as an address.

module Messaging = Capability_Messaging

let withEnv = (key, value, f) => {
  Dict.set(NodeProcess.env, key, value)
  let result = f()
  Dict.delete(NodeProcess.env, key)
  result
}

describe("Capability_Messaging — reading a configured value", () => {
  // Only the env-var rung is reachable here: the rungs below it end at
  // `Pulumi.Config`, which needs a deploy-time runtime this suite does not have.
  // `configured` returns before touching it whenever the variable is set.
  testSync("an address set in the environment is the sender", () => {
    let sender = withEnv("REVENTLESS_MESSAGING_EMAIL_SENDER", "mail@shop.test", () =>
      Messaging.configured(Messaging.emailSenderKey)
    )
    expect(sender)->toEqual(Some("mail@shop.test"))
  })

  // A stray `REVENTLESS_MESSAGING_EMAIL_SENDER=` in CI, or a blank line in the
  // sidecar. Reading it as an address asks SES for an identity with none.
  testSync("an empty value is not an address", () => {
    let sender = withEnv("REVENTLESS_MESSAGING_EMAIL_SENDER", "", () =>
      Messaging.configured(Messaging.emailSenderKey)
    )
    expect(sender)->toEqual(None)
  })

  // The one that is not obviously empty: a key left with a space after the colon.
  // It reached SES as an identity request for " " before this was trimmed.
  testSync("a whitespace-only value is not an address either", () => {
    let sender = withEnv("REVENTLESS_MESSAGING_EMAIL_SENDER", "   ", () =>
      Messaging.configured(Messaging.emailSenderKey)
    )
    expect(sender)->toEqual(None)
  })

  testSync("a surviving value is the trimmed one", () => {
    let sender = withEnv("REVENTLESS_MESSAGING_EMAIL_SENDER", "  mail@shop.test  ", () =>
      Messaging.configured(Messaging.emailSenderKey)
    )
    expect(sender)->toEqual(Some("mail@shop.test"))
  })

  testSync("the sms sender reads off its own key", () => {
    let sender = withEnv("REVENTLESS_MESSAGING_SMS_SENDER", "+15550100", () =>
      Messaging.configured(Messaging.smsSenderKey)
    )
    expect(sender)->toEqual(Some("+15550100"))
  })
})

describe("Capability_Messaging — choosing a transport", () => {
  testSync("ses and log are the two a stack can name", () => {
    let pair: (Messaging.emailProvider, Messaging.emailProvider) = (Ses, Log)
    expect((Messaging.parseEmailProvider("ses"), Messaging.parseEmailProvider("log")))->toEqual(pair)
  })

  // Config files are written by hand; a capitalised or padded value means what it
  // says, and refusing it would be pedantry rather than safety.
  testSync("the value is read case- and whitespace-insensitively", () => {
    expect(Messaging.parseEmailProvider("  LOG "))->toEqual(Messaging.Log)
  })

  // The one that matters: defaulting a typo to SES would provision a real
  // identity for a stack that asked to only log.
  testSync("an unrecognised transport is refused, not defaulted", () => {
    let outcome = try {
      let _ = Messaging.parseEmailProvider("smtp")
      None
    } catch {
    | JsExn(e) => e->JsExn.message
    }
    expect(outcome->Option.getOr("")->String.includes("is not an email provider"))->toBe(true)
  })

  // SES is the default so that a deployment saying nothing still mails: a stack
  // that means not to send says so, rather than silence meaning it.
  testSync("a named transport wins over the default", () => {
    let chosen = withEnv("REVENTLESS_MESSAGING_EMAIL_PROVIDER", "log", () => Messaging.emailProvider())
    let expected: Messaging.emailProvider = Log
    expect(chosen)->toEqual(expected)
  })
})

describe("Capability_Messaging — the log transport's default sender", () => {
  // Hard-coded where the SES address is required, because a logged message
  // reaches nobody. `.test` can never resolve, so it cannot be a real inbox.
  testSync("is a reserved address", () => {
    expect(Messaging.logDefaultAddress->String.endsWith(".test"))->toBe(true)
  })
})
