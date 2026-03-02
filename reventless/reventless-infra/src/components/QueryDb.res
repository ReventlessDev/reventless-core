/**
Errors that can occur during read model storage operations.

Returned as the error variant in `Result.t` by read model operations that
interact with the underlying query database (e.g. DynamoDB).
*/
@schema
type storageError =
  /** A write operation failed to persist the state. */
  | NotSavedToStorage(string)
  /** A read operation failed to retrieve the state. */
  | NotLoadedFromStorage(string)
  /** A count operation failed. */
  | NotCountedOnStorage(string)
  /** A delete operation failed. */
  | NotDeletedFromStorage(string)
  /** A batch write did not fully succeed (some items may not have been written). */
  | BatchNotFullyWrittenToStorage(string)
  /** A conditional write failed because the state was modified concurrently. */
  | StaleState
  /** A composite-key (sub-ID) operation was attempted but no sub-ID config was provided. */
  | MissingSubIdConfig

/**
A function that derives the infrastructure resources needed to back GraphQL resolvers,
given the set of all query database outputs in the plugin.
*/
type rec resolversResourcesMaker = dict<outputs> => array<Adapter.resource>

/**
Deploy-time outputs produced when a `QueryDb` is provisioned.

- `resources` — the underlying database infrastructure resources
- `resolversMaker` — callback used by the plugin to assemble resolver resources
*/
and outputs = {
  resources: array<Adapter.resource>,
  resolversMaker: resolversResourcesMaker,
}

/** A dictionary of query database outputs keyed by read model name. */
type allOutputs = dict<outputs>
