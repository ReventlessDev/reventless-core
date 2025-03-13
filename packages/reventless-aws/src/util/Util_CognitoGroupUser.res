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
    PulumiAws.IAM.Policy.make(
      ~name=name ++ "AddRemoveUserToGroup",
      ~args={
        PulumiAws.IAM.Policy.policy: PulumiAws.PolicyDocument.make(
          ~statements=[
            {
              effect: PulumiAws.PolicyDocument.Allow,
              actions: PulumiAws.PolicyDocument.Action("cognito-idp:AdminAddUserToGroup"),
              resources: PulumiAws.PolicyDocument.Resource(`${userPoolArn}`),
            },
            {
              effect: PulumiAws.PolicyDocument.Allow,
              actions: PulumiAws.PolicyDocument.Action("cognito-idp:AdminRemoveUserFromGroup"),
              resources: PulumiAws.PolicyDocument.Resource(`${userPoolArn}`),
            },
          ],
        )
        ->PulumiAws.PolicyDocument.toJsonString
        ->Pulumi.Input.make,
      },
      ~opts?,
    )
  })
