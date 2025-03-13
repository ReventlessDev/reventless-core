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
) => Pulumi.Output.t<PulumiAws.PolicyDocument.t> = (~identity, ~opts=?) =>
  identity.arn->Pulumi.Output.flatMap(identityArn => {
    open PulumiAws.PolicyDocument
    PulumiAws.PolicyDocument.make(
      ~statements=[
        {
          sid: "AllowSES",
          principal: Principals({aws: PrincipalId("*")}),
          effect: Allow,
          actions: Actions(["SES:SendEmail", "SES:SendRawEmail"]),
          resources: Resource(identityArn),
        },
      ],
    )->Pulumi.Output.make
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
      ->Pulumi.Output.apply(policyDocument => policyDocument->PulumiAws.PolicyDocument.toJsonString)
      ->Pulumi.Output.asInput,
    },
    ~opts?,
  )
}
