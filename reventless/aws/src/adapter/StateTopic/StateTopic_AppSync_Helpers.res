// Pulumi-free helpers for the state-topic relay's deploy-time registration.
//
// Split out of `StateTopic_AppSync.res` so the key-schema check can be driven
// headlessly — the registration module itself pulls in @pulumi/aws.

/** The attribute name `StateTopic_AppSync_Ops.entityKeyFromRecord` looks for when
    it builds a change descriptor's entity key from the stream record's `Keys`.
    Every framework-provisioned QueryDb table uses it; a self-provisioned table
    registered through `makeForTable` must too. */
let entityKeyPartitionAttribute = "id"

/** Reject a table whose partition attribute is not `id`.

    The relay does not fail on such a table — it publishes descriptors carrying a
    joined-and-sorted fallback key, which surfaces much later as clients
    refetching the wrong entity. Turning that into a build error is the whole
    point: the message names the table and its actual key so the fix is obvious
    at the registration site.

    At most one sort key needs no check — DynamoDB tables cannot have more than
    one, so the relay's `{id}-{sortValue}` composition is total by construction.

    Naming the table costs one thing worth knowing: the caller resolves the table
    name to build the message, so on the very first deploy of a NEW table — where
    that name is still unknown at preview — the failure lands during the update
    rather than the preview. It fails the deploy either way. */
let checkPartitionKeyName = (~tableName: string, ~partitionKeyName: string): unit =>
  if partitionKeyName != entityKeyPartitionAttribute {
    JsError.throwWithMessage(
      `StateTopic: table "${tableName}" is keyed on "${partitionKeyName}", but the ` ++
      `state-topic relay derives a change descriptor's entity key from an attribute ` ++
      `named "${entityKeyPartitionAttribute}". Registering it would publish ` ++
      `descriptors whose id does not match the row. Rename the partition key to ` ++
      `"${entityKeyPartitionAttribute}", or do not register this table.`,
    )
  }
