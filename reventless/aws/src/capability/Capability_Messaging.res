// The messaging capability a deployment provisions: which transport, sending as
// whom. The entry point a platform root calls; the transports sit below it.
//
// **All of it is configuration, none of it is code.** Which transport is a
// per-environment decision — a staging stack should not mail customers, and
// nothing about the shop it deploys says so — and the address is a per-account
// fact, since SES sends from one verified identity. A repository cannot know
// either, and a placeholder default for the address is worse than none: it
// provisions an identity nobody can verify, after which every send is refused at
// the sender while reading like a delivery problem.
//
// Config keys, on the usual ladder — env var `REVENTLESS_<SCREAMING_SNAKE>`, then
// `Pulumi.local.yaml`, then `platform:<key>` in `Pulumi.<stack>.yaml`:
//
//   - `messagingEmailProvider`   — "ses" (default) or "log". Per channel, like
//                                  the senders: an SMS transport will bring its own.
//   - `messagingEmailSender`     — the address messages are sent from. Under
//                                  `ses` it is verified and required; under
//                                  `log` it is only a header and defaults.
//   - `messagingEmailSenderName` — optional display name for the `From:` header.
//   - `messagingSmsSender`       — origination number or sender id. Carried only;
//                                  no transport reads it yet.
//
// **Unset is a real answer, and the deploy still checks it.** A platform whose
// plugins declare the Messaging capability and which provisions no sender is
// refused at deploy time by `Platform.deployPlatform`, naming the key — so "no
// mail configured" cannot reach production as silence.

let emailProviderKey = "messagingEmailProvider"
let emailSenderKey = "messagingEmailSender"
let emailSenderNameKey = "messagingEmailSenderName"
let smsSenderKey = "messagingSmsSender"

/** One key off the ladder, trimmed, with blank read as absent.

    Blank matters because the ways to write "nothing" must not differ: a stray
    `REVENTLESS_MESSAGING_EMAIL_SENDER=` in CI, a blank line in
    `Pulumi.local.yaml`, and a key left with a space after the colon all mean the
    stack named no sender. Honouring any of them would ask SES for an identity
    with a blank address — a deploy failure whose cause is whitespace, and one
    that reaches AWS before anything here explains it.

    Trimmed rather than only compared, so a value that survives is also the value
    used: an address with a trailing space is a `From:` header with one. */
let configured = (key: string): option<string> =>
  switch Util_LocalConfig.get(key) {
  | Some(_) as v => v
  | None => Pulumi.Config.make(Some("platform"))->Pulumi.Config.get(key)
  }->Option.flatMap(value => {
    let trimmed = value->String.trim
    trimmed === "" ? None : Some(trimmed)
  })

/** The transports a deployment can choose between for the EMAIL channel. The name travels to the
    Lambdas, so it is also the wire value — one spelling, not a deploy-time enum
    and a runtime string that can disagree. */
type emailProvider =
  | Ses
  | Log

let emailProviderName = (provider: emailProvider): string =>
  switch provider {
  | Ses => "ses"
  | Log => "log"
  }

/**
Which transport this stack asked for. SES is the default, so a deployment that
says nothing gets the real one — the safe direction is that mail works, and a
stack opting out of sending says so explicitly.

An unrecognised value is refused rather than defaulted. Falling back to SES on a
typo would provision a real identity for a stack that asked to only log, which
is the one mistake this key exists to prevent.
*/
let parseEmailProvider = (raw: string): emailProvider =>
  switch raw->String.trim->String.toLowerCase {
  | "ses" => Ses
  | "log" => Log
  | other =>
    JsError.throwWithMessage(
      `platform:${emailProviderKey} is "${other}", which is not an email provider.\n` ++
      `  Known values: "ses" (default — a verified SES identity) and "log" ` ++
      `(writes each message to the log, sends nothing).`,
    )
  }

let emailProvider = (): emailProvider =>
  configured(emailProviderKey)->Option.mapOr(Ses, parseEmailProvider)

/** The `From:` a log-transport deployment presents as when the stack named no
    address.

    Hard-coded where the SES address is required, and the asymmetry follows from
    what the value is for: a logged message reaches nobody, so there is nothing to
    verify and nothing that differs per environment. `.test` is reserved for
    exactly this (RFC 6761) — it can never resolve, so an address escaping into a
    fixture cannot reach a real inbox. */
let logDefaultAddress = "notifications@online-shop.test"

/**
Provision the capability and hand back the platform's messaging handle.

`~name` is used only by the SES arm, which is the only arm with a resource: the
log transport is a runtime decision carried in an environment variable, so choosing it
creates nothing and costs nothing to leave configured on a stack that is torn
down and rebuilt.
*/
let make = (
  ~name: string,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
): ReventlessInfra.Platform.messagingSender => {
  // Read whether or not there is an email sender: the SMS half is independent,
  // and a stack may state one without the other.
  let smsSender = configured(smsSenderKey)->Option.map(Pulumi.Input.make)
  let chosen = emailProvider()
  let displayName = configured(emailSenderNameKey)
  let providerInput = Pulumi.Input.make(chosen->emailProviderName)

  switch (chosen, configured(emailSenderKey)) {
  // Asked for SES and named no address. Nothing is provisioned, and the deploy
  // gate refuses this the moment a plugin declares it needs messaging — here
  // rather than there because this module has no view of what the plugins want.
  | (Ses, None) => {emailProvider: providerInput, smsSender: ?smsSender}
  | (Ses, Some(address)) => {
      emailSender: Capability_Messaging_Ses.emailSender(~name, ~address, ~displayName, ~opts?),
      emailProvider: providerInput,
      smsSender: ?smsSender,
    }
  | (Log, address) => {
      emailSender: Pulumi.Input.make(
        Reventless.Messaging.fromHeader(
          ~displayName,
          ~address=address->Option.getOr(logDefaultAddress),
        ),
      ),
      emailProvider: providerInput,
      smsSender: ?smsSender,
    }
  }
}
