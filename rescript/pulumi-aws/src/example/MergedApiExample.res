// Compile-only smoke for the Merged-API bindings: a MERGED GraphQLApi, a
// GRAPHQL source API with a declarative inline schema, and the
// SourceApiAssociation linking them under AUTO_MERGE. Not executed at deploy
// time — it keeps the three binding surfaces type-checked together.
// Validated on real AWS by the Phase-0 spike of
// docs/plans/done/merged-api-push-free-composition.md.

let mergedExecRole = IAM.Role.make(
  ~name="example-merged-exec-role",
  ~args={
    assumeRolePolicy: Pulumi.Input.make(
      `{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"appsync.amazonaws.com"},"Action":"sts:AssumeRole"}]}`,
    ),
  },
)

let iamSecondaryAuth: AppSync.GraphQLApi.additionalAuthenticationProvider = {
  authenticationType: Pulumi.Input.make(AppSync.GraphQLApi.AWS_IAM),
}

let mergedApi = AppSync.GraphQLApi.make(
  ~name="example-domain-merged",
  ~args={
    authenticationType: Pulumi.Input.make(AppSync.GraphQLApi.AMAZON_COGNITO_USER_POOLS),
    userPoolConfig: Pulumi.Input.make({
      AppSync.GraphQLApi.userPoolId: "eu-west-1_example",
      defaultAction: AppSync.GraphQLApi.ALLOW,
    }),
    additionalAuthenticationProviders: Pulumi.Input.make([Pulumi.Input.make(iamSecondaryAuth)]),
    apiType: Pulumi.Input.make(AppSync.GraphQLApi.MERGED),
    mergedApiExecutionRoleArn: mergedExecRole.arn->Pulumi.Output.asInput,
  },
)

let sourceApi = AppSync.GraphQLApi.make(
  ~name="example-plugin-source",
  ~args={
    authenticationType: Pulumi.Input.make(AppSync.GraphQLApi.AMAZON_COGNITO_USER_POOLS),
    userPoolConfig: Pulumi.Input.make({
      AppSync.GraphQLApi.userPoolId: "eu-west-1_example",
      defaultAction: AppSync.GraphQLApi.ALLOW,
    }),
    schema: Pulumi.Input.make(`schema { query: Query }\ntype Query { ping: String }`),
  },
)

let association = AppSync.SourceApiAssociation.make(
  ~name="example-source-association",
  ~args={
    mergedApiId: mergedApi.id->Pulumi.Output.asInput,
    sourceApiId: sourceApi.id->Pulumi.Output.asInput,
    sourceApiAssociationConfigs: Pulumi.Input.make([
      Pulumi.Input.make({
        AppSync.SourceApiAssociation.mergeType: Pulumi.Input.make(
          AppSync.SourceApiAssociation.AUTO_MERGE,
        ),
      }),
    ]),
  },
)

let associationId = association.associationId
