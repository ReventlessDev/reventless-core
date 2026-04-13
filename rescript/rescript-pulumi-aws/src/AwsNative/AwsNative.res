/** Umbrella for @pulumi/aws-native bindings. Intentionally narrow —
    added only for resources that benefit from Cloud Control API semantics
    (e.g. AppSync Resolver's internal schema-propagation wait). */
module AppSync = {
  module Resolver = AwsNative_AppSync_Resolver
}
