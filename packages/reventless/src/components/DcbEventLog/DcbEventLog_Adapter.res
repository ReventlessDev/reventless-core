type rawStoredEvent = {
  eventType: string,
  data: JSON.t,
  tags: array<DcbTag.tag>,
}

type rawSequencedEvent = {
  position: DcbTag.sequencePosition,
  eventType: string,
  data: JSON.t,
  tags: array<DcbTag.tag>,
}

type rawReadResult = {
  events: array<rawSequencedEvent>,
  headPosition?: DcbTag.sequencePosition,
}

type operations = {
  read: (
    ~query: DcbTag.query,
    ~after: DcbTag.sequencePosition=?,
  ) => promise<rawReadResult>,
  append: (
    array<rawStoredEvent>,
    ~condition: DcbTag.appendCondition=?,
  ) => promise<result<DcbTag.sequencePosition, string>>,
}

type storage = {
  resources: array<ReventlessSpec.Adapter.resource>,
  operations: Pulumi.Output.t<operations>,
}

type storageMaker = (
  ~name: string,
  ~indexes: array<string>, // GSI names (e.g., ["tag_courseId", "tag_composite"])
  ~opts: Pulumi.CustomResourceOptions.t,
) => storage

module type Storage = {
  let make: storageMaker
}
