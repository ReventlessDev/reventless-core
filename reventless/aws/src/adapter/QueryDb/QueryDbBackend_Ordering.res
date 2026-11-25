/** How the store `QueryDbBackend` picked for this read model orders a list. */
let forReadModel = (name: string): ReventlessCore.QueryDb_Ordering.t =>
  QueryDbBackend.isPostgresFor(name)
    ? ReventlessPostgres.QueryDbStorage_Postgres_Ops.ordering
    : QueryDbStorage_DynamoDb.ordering
