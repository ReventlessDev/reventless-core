let userPoolId: Pulumi.Output.t(string);
let userPool: PulumiAws.Cognito.UserPool.t;

let userPoolClient: PulumiAws.Cognito.UserPoolClient.t;
let userPoolClientId: Pulumi.Output.t(string);
let identityPoolId: Pulumi.Output.t(string);

let graphQLSchema: string;

let api: PulumiAws.AppSync.GraphQLApi.t;
let apiRole: PulumiAws.IAM.Role.t;

let apiUrl: Pulumi.Output.t(string);
let apiName: Pulumi.Output.t(string);
let apiId: Pulumi.Output.t(string);
