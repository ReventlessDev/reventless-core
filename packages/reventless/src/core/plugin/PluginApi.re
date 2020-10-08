let graphQLSchema = "
type Extension {
	name: String!
	extensionPointName: String!
}

type ExtensionPoint {
	name: String!
	commandTopic: String!
	eventTopic: String
}

type Mutation {
	deactivatePlugin(id: ID!): String!
	activatePlugin(id: ID!): String!
}

type Plugin {
	id: ID!
	name: String!
	version: String!
	extensionPoints: [ExtensionPoint!]!
	extensions: [Extension!]!
	status: [String!]!
	since: String!
}

type Plugins {
	nextToken: String
	scannedCount: Int!
	items: [Plugin!]!
}

type Query {
	plugin(id: ID!): Plugin
	everyPlugin(nextToken: String, limit: Int): Plugins!
}
";
