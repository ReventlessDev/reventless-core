/** @pulumi/aws/appsync/SourceApiAssociation
  see: https://www.pulumi.com/registry/packages/aws/api-docs/appsync/sourceapiassociation

  Links a source `GraphQLApi` to a Merged API (`apiType: MERGED`). Creation
  triggers the initial schema merge; under `AUTO_MERGE` AWS re-merges on every
  source-API schema change (no further calls). AWS serializes association
  writes per merged API — concurrent creates against one merged API fail with
  409 `ConcurrentModificationException`, so first-time associations from
  parallel stacks need retry-with-backoff (steady-state schema updates are
  unaffected).
*/
type t = {
  id: Pulumi.Output.t<string>,
  arn: Pulumi.Output.t<string>,
  associationId: Pulumi.Output.t<string>,
}
type sourceApiAssociation = t

type mergeType =
  | AUTO_MERGE
  | MANUAL_MERGE

type sourceApiAssociationConfig = {mergeType: Pulumi.Input.t<mergeType>}

/** Identify each side by id or ARN (exactly one per side). */
type args = {
  mergedApiId?: Pulumi.Input.t<string>,
  mergedApiArn?: Pulumi.Input.t<string>,
  sourceApiId?: Pulumi.Input.t<string>,
  sourceApiArn?: Pulumi.Input.t<string>,
  sourceApiAssociationConfigs?: Pulumi.Input.t<
    array<Pulumi.Input.t<sourceApiAssociationConfig>>,
  >,
  description?: Pulumi.Input.t<string>,
}

@module("@pulumi/aws") @scope("appsync") @new
external make: (
  ~name: string,
  ~args: args=?,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
) => sourceApiAssociation = "SourceApiAssociation"
