// The messaging sender a dev platform provisions — the local counterpart to
// `Capability_Messaging_Ses`, and reached the same way: a root calls `make`,
// passes the handle as `~messagingSender` in `~hostUiBundle`, and the platform
// puts a provider on the capability record every slice's `translate` receives.
// Nothing about a plugin changes between the two.
//
// **The address is hard-coded here, where on AWS it is configuration.** That is
// the one deliberate difference, and it follows from what the value is for. A
// verified identity is a per-account fact a repository cannot know, so the AWS
// helper refuses to invent one; a logged message reaches nobody, so there is
// nothing to verify, nothing that differs per developer, and nothing a setting
// would buy. `.test` is reserved for exactly this (RFC 6761) — it can never
// resolve, so an address escaping into a fixture cannot reach a real inbox.

/** The `From:` this platform's mail would carry when its root names none. Named
    for the platform rather than the shop: what a dev is looking at when they read
    it is the local log transport, and a name that impersonated the deployment
    would make a screenshot of a dev run indistinguishable from one of production. */
let senderName = "Online Shop (local)"
let senderAddress = "notifications@online-shop.test"

/** The sender for an app of this name: the app's name marked local, and an
    address under `.test` made from it (`Amperia` is `notifications@amperia.test`). */
let senderFor = (~appName: string): (string, string) => {
  let slug =
    appName
    ->String.toLowerCase
    ->String.replaceRegExp(/[^a-z0-9]+/g, "-")
    ->String.replaceRegExp(/^-+|-+$/g, "")
  (`${appName} (local)`, `notifications@${slug == "" ? "app" : slug}.test`)
}

/**
The handle, in the shape the platform config takes. A root names its app
(`~appName`) so its mail says whose it is; with none, the platform's own sender.

`Pulumi.Input.t` in a platform that runs no Pulumi is not an accident: the field
belongs to the shared `Platform.messagingSender`, so both platforms carry the
sender in one type and a root moving between them changes which helper it calls
and nothing else. `Input.make` is the identity function, so what travels is the
string.

The header is built by `Messaging.fromHeader`, the same function the SES helper
applies to its verified address — one formatter, so the two platforms cannot
present the same deployment under two differently-escaped names.
*/
let make = (~appName: option<string>=?, ()): ReventlessInfra.Platform.messagingSender => {
  let (name, address) =
    appName->Option.mapOr((senderName, senderAddress), appName => senderFor(~appName))
  {
    emailSender: Pulumi.Input.make(
      Reventless.Messaging.fromHeader(~displayName=Some(name), ~address),
    ),
  }
}
