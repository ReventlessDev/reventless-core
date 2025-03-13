let addUserGroup = (~name: string, ~userPoolId: Pulumi.Output.t<string>) =>
  PulumiAws.Cognito.UserGroup.make(
    ~name="UserGroup-" ++ name,
    ~args={
      PulumiAws.Cognito.UserGroup.name: name->Pulumi.Input.make,
      userPoolId: userPoolId->Pulumi.Output.asInput,
    },
  )

let makeAddRemoveUserToGroupPolicy = (
  ~name: string,
  ~userPoolArn: Pulumi.Output.t<string>,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
) =>
  userPoolArn->Pulumi.Output.apply(userPoolArn => {
    open PulumiAws.PolicyDocument
    PulumiAws.IAM.Policy.make(
      ~name=name ++ "AddRemoveUserToGroup",
      ~args={
        PulumiAws.IAM.Policy.policy: PulumiAws.PolicyDocument.make(
          ~statements=[
            {
              sid: "AllowAdminAddRemoveUserToGroup",
              effect: Allow,
              actions: Actions(["cognito-idp:AdminAddUserToGroup", "cognito-idp:AdminRemoveUserFromGroup"]),
              resources: Resource(`${userPoolArn}`),
            },
          ],
        )
        ->PulumiAws.PolicyDocument.toJsonString
        ->Pulumi.Input.make,
      },
      ~opts?,
    )
  })
