// A verified SES sender identity — the email channel's real transport.
//
// Provisioning only. Which transport a deployment uses, and what address it
// sends from, are read by `Capability_Messaging`, which is the entry point a
// platform root calls; this module receives a resolved address and creates the
// identity for it. Split that way because a deployment can choose *not* to have
// an SES identity, and a module that read its own config could not be left
// uncalled without also leaving the config unread.
//
// **Verification is not instant and not automatic.** Creating the identity asks
// AWS to send a confirmation mail to the address; until somebody follows it, SES
// refuses every send. That is a deployment step this code cannot perform, and a
// deploy that "succeeded" is not evidence mail flows — which is why the runtime
// treats an SES refusal as retryable, so the first sends queue rather than being
// written off while the address is still pending.
//
// A deployment in the SES sandbox may also only send *to* verified addresses.
// Leaving the sandbox is an account-level request, not a resource.

open PulumiAws

/**
Create the identity and hand back the `From:` it sends as.

`~name` is the Pulumi resource name — a URN rather than a setting, so it stays in
code: moving it to config would replace the resource whenever a stack spelled it
differently.

The identity is created for the bare address, because SES verifies an address and
not a header; the display name is applied afterwards, to the value the send path
reads. Applied over the identity's own output rather than over the configured
string, so the sender a Lambda is handed still depends on the resource existing.
*/
let emailSender = (
  ~name: string,
  ~address: string,
  ~displayName: option<string>,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
): Pulumi.Input.t<string> => {
  let identity = SES.EmailIdentity.make(~name, ~args={email: address}, ~opts?)
  identity.email
  ->Pulumi.Output.apply(verified => Reventless.Messaging.fromHeader(~displayName, ~address=verified))
  ->Pulumi.Output.asInput
}
