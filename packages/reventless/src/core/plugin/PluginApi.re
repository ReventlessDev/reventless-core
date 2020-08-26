let graphQLSchema = "
type Extension {
	id: String!
	commandTopic: String!
	eventTopic: String!
}

type ExtensionPoint {
	id: String!
	commandTopic: String!
	eventTopic: String
}

type Mutation {
	deactivatePlugin(id: ID!): String!
	activatePlugin(id: ID!): String!
}

type Plugin {
	name: String!
	version: String!
	extensionPoints: [ExtensionPoint!]!
	extensions: [Extension!]!
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
