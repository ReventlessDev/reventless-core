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
  ~opts: Pulumi.CustomResourceOptions.t,
) => storage

module type Storage = {
  let make: storageMaker
}
