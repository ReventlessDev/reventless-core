let addUserGroup = (~name: string, ~userPool: PulumiAws.Cognito.UserPool.t) =>
  PulumiAws.Cognito.UserGroup.make(
    ~name="UserGroup-" ++ name,
    ~args=
      PulumiAws.Cognito.UserGroup.Args.make(
        ~name=name->Pulumi.Input.wrap,
        ~userPoolId=userPool##id->Pulumi.Output.asInput,
        (),
      ),
    (),
  );

let makeAddRemoveUserToGroupPolicy =
    (
      ~name: string,
      ~userPoolArn: string,
      ~opts: option(Pulumi.CustomResourceOptions.t)=?,
      _: unit,
    ) =>
  PulumiAws.IAM.Policy.make(
    ~name=name ++ "AddRemoveUserToGroup",
    ~args=
      PulumiAws.IAM.Policy.Args.makeFromString(
        ~policy=
          {j|{
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
          }|j},
        (),
      ),
    ~opts?,
    (),
  );
