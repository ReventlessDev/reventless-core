type rawStoredEvent = {
  eventType: string,
  data: JSON.t,
  tags: array<Reventless.DcbTag.tag>,
  meta: Reventless.Message.meta,
}

type rawSequencedEvent = {
  position: Reventless.DcbTag.sequencePosition,
  eventType: string,
  data: JSON.t,
  tags: array<Reventless.DcbTag.tag>,
  meta: Reventless.Message.meta,
  recordedAt: string,
}

type rawReadResult = {
  events: array<rawSequencedEvent>,
  headPosition?: Reventless.DcbTag.sequencePosition,
}

type operations = {
  read: (
    ~query: Reventless.DcbTag.query,
    ~after: Reventless.DcbTag.sequencePosition=?,
  ) => promise<rawReadResult>,
  append: (
    array<rawStoredEvent>,
    ~condition: Reventless.DcbTag.appendCondition=?,
  ) => promise<result<Reventless.DcbTag.sequencePosition, ReventlessInfra.DcbEventLog.appendError>>,
  readStream: (
    ~query: Reventless.DcbTag.query,
    ~after: Reventless.DcbTag.sequencePosition=?,
    ~strongConsistency: bool=?,
  ) => Stream.t<rawSequencedEvent, string, unit>,
  /** Reads the fences of cross-partition tags, strongly consistent, for a reader
      of an eventually consistent index to check its read against. Absent on a
      store whose reads are never stale. */
  readFences?: array<Reventless.DcbTag.tag> => promise<array<Reventless.DcbFenceCount.fence>>,
}

type storage = {
  resources: array<ReventlessInfra.Adapter.resource>,
  operations: Pulumi.Output.t<operations>,
}

type storageMaker = (
  ~name: string,
  ~indexes: array<string>,
  ~partitionTag: Reventless.DcbTag.derivedPartitionTag,
  /** Tag keys declared `@crossPartition` across the produced event schemas.
      A single-tag decision read of such a key reads every partition carrying it
      (per-tag GSI) and its consistency fence is bumped by every carrier. Derived
      once at build time so read-scope = fence-scope per tag. */
  ~crossPartitionTagKeys: array<string>=?,
  /** Key -> the event types with a pair fence on it (`DcbScopeInference.pairFenceTypes`):
      every append of such a type carrying the key moves that fence. */
  ~pairFenceTypes: dict<array<string>>=?,
  ~opts: Pulumi.CustomResourceOptions.t,
) => storage

module type Storage = {
  let make: storageMaker
}
