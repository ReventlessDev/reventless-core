---
title: Api
date: 2024-08-13
draft: false
---

The API is used to query and mutate a [ReadModel](readmodel.md). As of writing, the API does not yet utilize the strong type system provided by Rescript. Therefore, instead of relying on the defined types inside the ReadModel, the programmer has to define the schema by hand. Once defined, a client can access the ReadModel to read or mutate the ReadModel state. 

## Schema

There are three main parts of the Schema. Types, Queries and Mutations. The Schema strongly depends on [GraphQL](https://graphql.org/learn/schema/). As such, use the GraphQL reference when defining more complex Schemata. 

Continuing on the Customer example, we might define the API as follows: 

```rescript title="Customer_Api.res" showLineNumbers
let typesSchema = "
  type Customer {
    id: ID!
    name: String!
    address: String!
  }

  input CustomerInput {
    name: String!
    address: String!
  }

  type Customers {
    nextToken: String
    scannedCount: Int!
    items: [Customer!]!
  }
"

let queriesSchema = "
  customer(id: ID!): Customer
  customerByName(name: String!): Customers!
  everyCustomer(nextToken: String, limit: Int): Customers!
"

let mutationsSchema = "
  Customer_Create(id: ID!, customer: CustomerInput!): String!
  Customer_ChangeAddress(id: ID!, address: String!): String!
  Customer_ChangeName(id: ID!, name: String!): String!
  Customer_Delete(id: ID!): String!
"


let graphQLSchema = j`
$typesSchema

type Query {
$queriesSchema
}

type Mutation {
$mutationsSchema
}
`

```

### typesSchema
The TypesSchema defines the types which will be used in GraphQL. In this example, the Customer Type represents a single customer. The CustomerInput defines a more complex argument. A `type` should represent a single instance, while an `input` serves to define input parameters that are not of the predefined GraphQL Types. Note the id field, since the Customer is stored using one in the Database. The id should have the same data type as provided in the [ReadModelSpec](./readmodel.md#read-model-spec).

 Usually it is good practice to give more than one result per query. For this we define the Customers type in the Schema. This type usually has a nextToken, since the amount of results could be overwhelming for the client application or lead to higher costs. The scannedCount can keep track of the amount of items already loaded. The items field contains the Customer entries as an Array. 

### queriesSchema
The QueriesSchema defines the Queries that should be accessible to a Client. Queries operate on the ReadModel rather than an aggregate. In this example, we have one query to get a unique customer. The customerByName query gets all Customers with the requested name. Note that the name is not a unique id, therefore more than one result can be returned. When we want to query over all Customer entries, the everyCustomer query will return all customers. 

### mutationsSchema
The MutationsSchema defines the accessible Mutations. A Mutation in Reventless often just sends a command to an [Aggregate](./aggregate.md). The Customer Aggregate triggers via commands. The mutation can usually have the same name as the command. However, since there might be more than one Aggregate per API, is makes sense to prefix the mutation with the Aggregate name to avoid confusion during manual testing (e.g. aws appsync console). The mutation should be defined analog to the command, using the GraphQL syntax.  

### graphQLSchema

Once we have defined the three components of the API schema, we need to put them together into a graphQLSchema. This way we get a full GraphQL schema which can be used in our application. It would be possible to define the full schema here, but we will see later why this might not be ideal. 

Once the graphQLSchema is defined, we must add it to our [Config](../reventless-common-modules/config.md) for the API to appear in the application.  

```rescript title="Config.res" showLineNumbers
...
let api: api = {
  open PulumiAws.AppSync.GraphQLApi
  make(
    ~name="CustomerApi",
    ~args=Args.make(
      ~authenticationType=#AMAZON_COGNITO_USER_POOLS->Pulumi.Input.make,
      ~userPoolConfig=userPoolId
      ->Pulumi.Output.apply(userPoolId =>
        UserPoolConfig.make(~userPoolId, ~defaultAction=#ALLOW, ())
      )
      ->Pulumi.Output.asInput,
      ~schema=CustomerApi.graphQLSchema->Pulumi.Input.make,
      (),
    ),
    (),
  )
}->Pulumi.Output.make
...
```

After adding the API to our config, the API should be accessible via e.g. AppSync

## Combining multiple Schemata to one API

When working with mutiple Schemata, it often makes sense to declare each schema in one file and import it into one API file. There, simply concatenate each Types, Queries and Mutations Schema and assign it to get one common API. 

```rescript title="ApiSchema.res" showLineNumbers
module type ApiSchema = {
  let typesSchema: string
  let queriesSchema: string
  let mutationsSchema: string
}

let make: array<module(ApiSchema)> => string = schemas => {
  let (typesSchema, queriesSchema, mutationsSchema) = schemas->Belt.Array.reduce(("", "", ""), (
    (typesSchema, queriesSchema, mutationsSchema),
    schema,
  ) => {
    module Schema = unpack(schema)
    (
      typesSchema ++ Schema.typesSchema,
      queriesSchema ++ Schema.queriesSchema,
      mutationsSchema ++ Schema.mutationsSchema,
    )
  })
  `
${typesSchema}

type Query {
${queriesSchema}
}

type Mutation {
${mutationsSchema}
}
`
}

let graphQLSchema = ApiSchema.make([
  module(CustomerApi),
  module(SubscriptionApi),
  module(PublisherApi),
])
```

The module type ApiSchema stores all three components of the full API schema. Using the make function, we can provide an array of modules (files) that define the API using a typesSchema, queriesSchema and mutationsSChema. It then folds them into a single schema definition. The graphQLSchema in this example combines the schemata of three APIs into one. This gives a unified API where new schemata can be added without modifying the [Config](../reventless-common-modules/config.md) file.

## Related Components

- **[ReadModel](./readmodel.md)** - Provides queryable state that the API exposes via GraphQL queries
- **[QueryDb](./querydb.md)** - Storage backend for ReadModel state that API queries access
- **[CommandGenerator](./commandgenerator.md)** - Transforms API mutations into aggregate commands
- **[Aggregate](./aggregate.md)** - Receives commands generated from API mutations

