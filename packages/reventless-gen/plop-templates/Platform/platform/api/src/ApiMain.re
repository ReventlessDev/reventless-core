open Pulumi;

let userPoolId =
  switch (Config.make(Some("userPool"))->Config.get("id")) {
  | Some(id) => id
  | _ =>
    StackReference.(
      make(Config.make(Some("userPool"))->Config.require("stack"))
      ->requireOutput("userPoolId"->Input.wrap)
    )
  };
let userPool =
  PulumiAws.Cognito.UserPool.get(
    ~name="UserPool",
    ~id=userPoolId->Output.asInput,
    (),
  );

let userPoolClient =
  PulumiAws.Cognito.UserPoolClient.(
    make(
      ~name="UserPoolClient-" ++ Pulumi.getStackName(),
      ~args=Args.make(~userPoolId=userPoolId->Output.asInput, ()),
      (),
    )
  );
let userPoolClientId = userPoolClient##id;

let identityPool =
  PulumiAws.Cognito.IdentityPool.make(
    ~userPoolId=userPool##id,
    ~userPoolClientId=userPoolClientId->Output.asInput,
    ~name="IdentityPool",
    ~allowUnauthenticatedIdentities=false,
    ~bucketArns=[||],
  );

let identityPoolId = identityPool##id;

let graphQLSchema = Node.Fs.readFileAsUtf8Sync("schema.gql");

let api =
  PulumiAws.AppSync.GraphQLApi.(
    make(~name="SLIMApi", ~userPoolId, ~schema=graphQLSchema->Input.wrap, ())
  );

let apiRole =
  PulumiAws.IAM.Role.makeWithDefaultPolicy(
    ~name="ApiRole",
    ~service="appsync.amazonaws.com"->Output.make,
    (),
  );

let apiId = api##id;
let apiUrl = api##uris->Output.apply(uris => uris##_GRAPHQL);
let apiName = api##name;
