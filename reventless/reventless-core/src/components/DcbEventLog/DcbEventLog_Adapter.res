type rawStoredEvent = {
  eventType: string,
  data: JSON.t,
  tags: array<ReventlessSpec.DcbTag.tag>,
}

type rawSequencedEvent = {
  position: ReventlessSpec.DcbTag.sequencePosition,
  eventType: string,
  data: JSON.t,
  tags: array<ReventlessSpec.DcbTag.tag>,
}

type rawReadResult = {
  events: array<rawSequencedEvent>,
  headPosition?: ReventlessSpec.DcbTag.sequencePosition,
}

type operations = {
  read: (
    ~query: ReventlessSpec.DcbTag.query,
    ~after: ReventlessSpec.DcbTag.sequencePosition=?,
  ) => promise<rawReadResult>,
  append: (
    array<rawStoredEvent>,
    ~condition: ReventlessSpec.DcbTag.appendCondition=?,
  ) => promise<result<ReventlessSpec.DcbTag.sequencePosition, string>>,
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
