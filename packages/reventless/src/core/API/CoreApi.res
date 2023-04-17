let typesSchema = PluginApi.typesSchema

let queriesSchema = PluginApi.queriesSchema

let mutationsSchema =
  PluginApi.mutationsSchema ++ `
	clone(restoreDateTime: String): String!
    @aws_auth(cognito_groups: ["Admin"])
`

let graphQLSchema = j`
$typesSchema

type Query {
$queriesSchema
}

type Mutation {
$mutationsSchema
}
`
