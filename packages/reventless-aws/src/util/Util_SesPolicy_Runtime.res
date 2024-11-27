let emailIdentity: (
  ~name: string,
  ~email: string,
  ~opts: Pulumi.CustomResourceOptions.t=?,
) => PulumiAws.SES.EmailIdentity.t = (~name, ~email, ~opts=?) =>
  PulumiAws.SES.EmailIdentity.make(~name="emailIdentity" ++ name, ~args={email: email}, ~opts?)

let fromCustomResourceOptions: option<
  Pulumi.CustomResourceOptions.t,
> => Pulumi.InvokeOptions.t = x =>
  switch x {
  | None => {}
  | Some(opts) => {Pulumi.InvokeOptions.parent: ?opts.parent, provider: ?opts.provider}
  }

let sesPolicyDocument: (
  ~identity: PulumiAws.SES.EmailIdentity.t,
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
) => PulumiAws.SES.IdentityPolicy.t = (~name, ~email, ~opts=?) => {
  let identity = emailIdentity(~name, ~email, ~opts?)

  PulumiAws.SES.IdentityPolicy.make(
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
