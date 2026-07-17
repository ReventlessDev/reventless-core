/** Central type definitions for AWS resources used by ReventlessCore.
  * 
  * All AWS-specific types should be defined here and imported from 
  * this module rather than directly from PulumiAws.
  * 
  * Usage: Since we're in the same package, use types directly:
  *   type api = Types.AppSync.api
  *   type role = Types.AppSync.role
  */
open PulumiAws

module AppSync = {
  // Base Pulumi types first
  type graphQLApi = AppSync.GraphQLApi.t
  type resolver = AppSync.Resolver.t
  type dataSource = AppSync.DataSource.t
  type function_ = AppSync.Function.t

  // Then types that use the base types (Output-wrapped)
  type api = Pulumi.Output.t<graphQLApi>
  type role = Pulumi.Output.t<IAM.Role.t>
}

module DynamoDb = {
  type table = DynamoDb.Table.t
}

module SQS = {
  type queue = SQS.Queue.t
}

module SNS = {
  type topic = SNS.Topic.t
}

module Lambda = {
  type function_ = Lambda.Function.t
  type role = IAM.Role.t
}
