let typesSchema = {|
type Extension {
	name: String!
	extensionPointName: String!
}

type ExtensionPoint {
	name: String!
	commandTopic: String!
	eventTopic: String
}

type StatusChange {
  at: String!
  by: String!
}

type Plugin {
	id: ID!
	name: String!
	version: String!
	extensionPoints: [ExtensionPoint!]!
	extensions: [Extension!]!
	status: [String!]!
  statusChange: StatusChange!
}

type Plugins {
	nextToken: String
	scannedCount: Int!
	items: [Plugin!]!
}
|};

let queriesSchema = {|
	plugin(id: ID!): Plugin
    @aws_auth(cognito_groups: ["Admin"])
	everyPlugin(nextToken: String, limit: Int): Plugins!
    @aws_auth(cognito_groups: ["Admin"])
|};

let mutationsSchema = {|
	Plugin_Deactivate(id: ID!): String!
    @aws_auth(cognito_groups: ["Admin"])
	Plugin_Activate(id: ID!): String!
    @aws_auth(cognito_groups: ["Admin"])
|};
