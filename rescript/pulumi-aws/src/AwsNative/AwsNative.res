/** Umbrella for @pulumi/aws-native bindings. Intentionally narrow —
    added only for resources that benefit from Cloud Control API semantics
    (e.g. AppSync Resolver's internal schema-propagation wait). */
module AppSync = {
  module Resolver = AwsNative_AppSync_Resolver
  /** AppSync Events (Pub/Sub) API — distinct from the GraphQL API. */
  module Api = AwsNative_AppSync_Api
  /** Channel namespace within an AppSync Events API. */
  module ChannelNamespace = AwsNative_AppSync_ChannelNamespace
}
