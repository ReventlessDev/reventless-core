open AdapterAws_Util_SES_Runtime;

let emailIdentity:
  (
    ~name: string,
    ~email: string,
    ~opts: Pulumi.CustomResourceOptions.t=?,
    unit
  ) =>
  EmailIdentity.t =
  (~name, ~email, ~opts=?, _unit) =>
    EmailIdentity.make(
      ~name="emailIdentity" ++ name,
      ~args=EmailIdentity.Args.make(~email),
      ~opts?,
      (),
    );

let fromCustomResourceOptions:
  option(Pulumi.CustomResourceOptions.t) => Pulumi.InvokeOptions.t =
  fun
  | None => Pulumi.InvokeOptions.make()
  | Some(opts) =>
    Pulumi.InvokeOptions.make(
      ~parent=?opts##parent,
      ~provider=?opts##provider,
      (),
    );

let sesPolicyDocument:
  (
    ~identity: EmailIdentity.t,
    ~opts: Pulumi.CustomResourceOptions.t=?,
    unit
  ) =>
  Pulumi.Output.t(Js.Promise.t(PulumiAws.IAM.GetPolicyDocument.t)) =
  (~identity, ~opts=?, _unit) =>
    identity##arn
    ->Pulumi.Output.apply(identityArn => {
        open PulumiAws.IAM.GetPolicyDocument;
        let principal =
          Args.Statement.Principal.make(~identifiers=[|"*"|], ~_type="AWS");
        let actions = [|"SES:SendEmail", "SES:SendRawEmail"|];
        let statement =
          Args.Statement.make(
            ~actions,
            ~principals=[|principal|],
            ~resources=[|identityArn|],
            (),
          );
        make(
          ~args=Args.make(~statements=[|statement|], ()),
          ~opts=opts |> fromCustomResourceOptions,
          (),
        );
      });

let identityWithPolicy:
  (
    ~name: string,
    ~email: string,
    ~opts: Pulumi.CustomResourceOptions.t=?,
    unit
  ) =>
  Pulumi.Output.t(IdentityPolicy.t) =
  (~name, ~email, ~opts=?, _unit) => {
    let identity = emailIdentity(~name, ~email, ~opts?, ());
    sesPolicyDocument(~identity, ~opts?, ())
    |> Pulumi.Output.apply(_, policyDocument =>
         IdentityPolicy.make(
           ~name="identityPolicy" ++ name,
           ~args=
             IdentityPolicy.Args.make(
               ~identity=identity##arn->Pulumi.Output.asInput,
               ~policy=(policyDocument |> Obj.magic)##json,
             ),
           ~opts?,
           (),
         )
       );
  };
