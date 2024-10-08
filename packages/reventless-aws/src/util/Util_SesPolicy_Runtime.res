let emailIdentity: (
  ~name: string,
  ~email: string,
  ~opts: Pulumi.CustomResourceOptions.t=?,
  unit,
) => PulumiAws.SES.EmailIdentity.t = (~name, ~email, ~opts=?, _unit) =>
  PulumiAws.SES.EmailIdentity.make(~name="emailIdentity" ++ name, ~args={email: email}, ~opts?, ())

let fromCustomResourceOptions: option<
  Pulumi.CustomResourceOptions.t,
> => Pulumi.InvokeOptions.t = x =>
  switch x {
  | None => Pulumi.InvokeOptions.make()
  | Some(opts) =>
    Pulumi.InvokeOptions.make(~parent=?opts["parent"], ~provider=?opts["provider"], ())
  }

let sesPolicyDocument: (
  ~identity: PulumiAws.SES.EmailIdentity.t,
  ~opts: Pulumi.CustomResourceOptions.t=?,
  unit,
) => Pulumi.Output.t<PulumiAws.IAM.GetPolicyDocument.t> = (~identity, ~opts=?, _unit) =>
  identity.arn->Pulumi.Output.flatMap(identityArn => {
    open PulumiAws.IAM.GetPolicyDocument
    let principal = Args.Statement.Principal.make(~identifiers=["*"], ~_type="AWS")
    let actions = ["SES:SendEmail", "SES:SendRawEmail"]
    let statement = Args.Statement.make(
      ~actions,
      ~principals=[principal],
      ~resources=[identityArn],
      (),
    )
    make(
      ~args=Args.make(~statements=[statement], ()),
      ~opts=opts->fromCustomResourceOptions,
      (),
    )->Pulumi.Output.fromPromise
  })

let identityWithPolicy: (
  ~name: string,
  ~email: string,
  ~opts: Pulumi.CustomResourceOptions.t=?,
  unit,
) => PulumiAws.SES.IdentityPolicy.t = (~name, ~email, ~opts=?, _unit) => {
  let identity = emailIdentity(~name, ~email, ~opts?, ())

  PulumiAws.SES.IdentityPolicy.make(
    ~name="identityPolicy" ++ name,
    ~args={
      identity: identity.arn->Pulumi.Output.asInput,
      policy: sesPolicyDocument(~identity, ~opts?, ())
      ->Pulumi.Output.apply(policyDocument => policyDocument["json"])
      ->Pulumi.Output.asInput,
    },
    ~opts?,
    (),
  )
}
