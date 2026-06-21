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
  ) => promise<result<Reventless.DcbTag.sequencePosition, string>>,
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
  ~opts: Pulumi.CustomResourceOptions.t,
) => storage

module type Storage = {
  let make: storageMaker
}
