/**
Where a plugin's ids and their types disagree. Needs the whole plugin, not one
file: whether `orderId` names an identity depends on whether any field is typed
`OrderId.t`, which is also what makes adoption opt-in per plugin — a plugin that
types nothing is never reported.

- **A field named for one identity and typed as another** (`orderId: CustomerId.t`):
  the mix-up the types exist to catch. A role name that is no identity of its own
  (`sellerId: CustomerId.t`) is fine.
- **An untyped `*Id` whose key has an identity** (`productId: string` beside a
  `ProductId.t`): the half-migrated state, where the compiler guards some uses and
  not others.
*/
type finding = {sliceName: string, message: string}

// The identity key a `*Id` / `*Ids` name gives by convention.
let nameKey = (name: string): option<string> =>
  if name->String.endsWith("Ids") {
    Some(name->String.slice(~start=0, ~end=name->String.length - 1))
  } else if name->String.length > 2 && name->String.endsWith("Id") {
    Some(name)
  } else {
    None
  }

let fieldsOf = (schema: S.t<unknown>): array<(string, S.t<unknown>)> => {
  let ofObject = (v: S.t<unknown>) =>
    switch v {
    | Object({properties}) => properties->Dict.toArray->Array.filter(((n, _)) => n != "TAG")
    | _ => []
    }
  switch schema {
  | AnyOf({anyOf}) => anyOf->Array.flatMap(ofObject)
  | other => ofObject(other)
  }
}

let slicesFields = (slice: DcbTag.sliceSchemas) =>
  [slice.commandSchema, slice.consumedEventSchema, slice.eventSchema]->Array.flatMap(fieldsOf)

let check = (slices: array<DcbTag.sliceSchemas>): array<finding> => {
  let declared: Set.t<string> = Set.make()
  slices->Array.forEach(slice =>
    slice
    ->slicesFields
    ->Array.forEach(((_, schema)) =>
      Semantic.fieldIdentityKey(schema)->Option.forEach(k => declared->Set.add(k))
    )
  )
  let seen: Set.t<string> = Set.make()
  let findings = []
  slices->Array.forEach(slice =>
    slice
    ->slicesFields
    ->Array.forEach(((name, schema)) => {
      let message = switch (Semantic.fieldIdentityKey(schema), nameKey(name)) {
      | (Some(key), Some(named)) if named != key && declared->Set.has(named) =>
        Some(
          `${name} is typed as a ${key}, but ${named} is an identity of its own in this plugin. Type it as ${named}'s identity, or rename the field.`,
        )
      | (None, Some(named)) if declared->Set.has(named) =>
        Some(
          `${name} is a plain string, but ${named} has an identity in this plugin. Type the field with it, so the compiler guards every use.`,
        )
      | _ => None
      }
      message->Option.forEach(
        message => {
          let id = slice.name ++ "\n" ++ message
          if !(seen->Set.has(id)) {
            seen->Set.add(id)
            findings->Array.push({sliceName: slice.name, message})
          }
        },
      )
    })
  )
  findings
}

/**
A slice partitioned by an identity another chapter declares: `categoryId`
partitioning a slice under `Product/`. The chapter is the default home of the
identity its slices decide about, so the two disagreeing usually means the slice
or the identity is in the wrong folder. `identityChapters` maps a key to the
chapter whose folder declares it; an identity declared in another package has
none and is not checked.
*/
let checkChapters = (
  ~identityChapters: dict<string>,
  ~partitionBySlice: dict<string>,
  slices: array<DcbTag.sliceSchemas>,
): array<finding> =>
  slices->Array.filterMap(slice =>
    switch (
      partitionBySlice->Dict.get(slice.name),
      slice.moduleUrl->Option.flatMap(DcbTag.chapterOfModuleUrl),
    ) {
    | (Some(key), Some(chapter)) =>
      switch identityChapters->Dict.get(key) {
      | Some(home) if home != chapter =>
        Some({
          sliceName: slice.name,
          message: `is partitioned by ${key}, which ${home}/ declares, but sits in ${chapter}/. Move the slice or the identity so they share a chapter.`,
        })
      | _ => None
      }
    | _ => None
    }
  )
