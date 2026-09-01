// A verified SES sender identity, provisioned with the framework's house
// conventions applied — the backing for the messaging capability's email channel.
//
// The identity is the whole of the provisioning: SES sends from a verified
// address, and everything else a send needs travels on the message. So this
// helper exists to make the sender a deploy-time decision with one owner rather
// than an environment variable each stack spells for itself.
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

/** Declare the sender address and hand back the platform's messaging handle.
    `~email` is the `From:` every message this deployment sends carries. */
let make = (
  ~name: string,
  ~email: string,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
): ReventlessInfra.Platform.messagingSender => {
  let identity = SES.EmailIdentity.make(~name, ~args={email: email}, ~opts?)

  {emailSender: identity.email->Pulumi.Output.asInput}
}
