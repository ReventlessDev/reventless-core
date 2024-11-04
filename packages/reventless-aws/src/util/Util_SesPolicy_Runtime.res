open Util_SES_Runtime

let emailIdentity: (
  ~name: string,
  ~email: string,
  ~opts: Pulumi.CustomResourceOptions.t=?,
) => EmailIdentity.t = (~name, ~email, ~opts=?) =>
  EmailIdentity.make(~name="emailIdentity" ++ name, ~args={email: email}, ~opts?)

let fromCustomResourceOptions: option<
  Pulumi.CustomResourceOptions.t,
> => Pulumi.InvokeOptions.t = x =>
  switch x {
  | None => {}
  | Some(opts) => {Pulumi.InvokeOptions.parent: ?opts.parent, provider: ?opts.provider}
  }

let sesPolicyDocument: (
  ~identity: EmailIdentity.t,
  ~opts: Pulumi.CustomResourceOptions.t=?,
) => Pulumi.Output.t<PulumiAws.IAM.policyDocument> = (~identity, ~opts=?) =>
  identity.arn->Pulumi.Output.flatMap(identityArn => {
    open PulumiAws.IAM
    let principal = {identifiers: ["*"], type_: "AWS"}
    let actions = ["SES:SendEmail", "SES:SendRawEmail"]
    let statement = {
      actions,
      principals: [principal],
      resources: [identityArn],
    }
    getPolicyDocument(
      ~args={statements: [statement]},
      ~opts=opts->fromCustomResourceOptions,
    )->Pulumi.Output.fromPromise
  })

let identityWithPolicy: (
  ~name: string,
  ~email: string,
  ~opts: Pulumi.CustomResourceOptions.t=?,
) => IdentityPolicy.t = (~name, ~email, ~opts=?) => {
  let identity = EmailIdentity.make(~name, ~args={email: email}, ~opts?)

  IdentityPolicy.make(
    ~name="identityPolicy" ++ name,
    ~args={
      identity: identity.arn->Pulumi.Output.asInput,
      policy: sesPolicyDocument(~identity, ~opts?)
      ->Pulumi.Output.apply(policyDocument => policyDocument.json)
      ->Pulumi.Output.asInput,
    },
    ~opts?,
  )
}
