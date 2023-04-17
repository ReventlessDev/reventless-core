let addUserGroup = (~name: string, ~userPoolId: Pulumi.Output.t<string>) =>
  PulumiAws.Cognito.UserGroup.make(
    ~name="UserGroup-" ++ name,
    ~args=PulumiAws.Cognito.UserGroup.Args.make(
      ~name=name->Pulumi.Input.make,
      ~userPoolId=userPoolId->Pulumi.Output.asInput,
      (),
    ),
    (),
  )

let makeAddRemoveUserToGroupPolicy = (
  ~name: string,
  ~userPoolArn: Pulumi.Output.t<string>,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
  _: unit,
) =>
  PulumiAws.IAM.Policy.make(
    ~name=name ++ "AddRemoveUserToGroup",
    ~args=PulumiAws.IAM.Policy.Args.makeFromString(
      ~policy=userPoolArn
      ->Pulumi.Output.apply(userPoolArn =>
        j`{
            "Version": "2012-10-17",
            "Statement": [
              {
                  "Effect": "Allow",
                  "Action": [
                      "cognito-idp:AdminAddUserToGroup"
                  ],
                  "Resource": "$userPoolArn"
              },
              {
                  "Effect": "Allow",
                  "Action": "cognito-idp:AdminRemoveUserFromGroup",
                  "Resource": "$userPoolArn"
              }
            ]
          }`
      )
      ->Pulumi.Output.asInput,
      (),
    ),
    ~opts?,
    (),
  )
