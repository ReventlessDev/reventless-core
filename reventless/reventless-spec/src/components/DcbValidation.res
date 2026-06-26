type validationError = {
  sliceName: string,
  message: string,
}

type variantInfo = {
  tagName: string,
  fields: dict<S.t<unknown>>,
  taggedFields: array<string>,
}

// Extract variant info (TAG name, fields, tagged fields) from a single variant schema
let extractVariantInfo = (variantSchema: S.t<unknown>): option<variantInfo> =>
  switch variantSchema {
  | Object({items, properties}) =>
    let tagName =
      items
      ->Array.find(item => item.location == "TAG")
      ->Option.flatMap(item =>
        switch item.schema {
        | String({const}) => Some(const)
        | _ => None
        }
      )
    tagName->Option.map(tagName => {
      let taggedFields =
        properties
        ->Dict.toArray
        ->Array.filterMap(((fieldName, fieldSchema)) =>
          if DcbTag.isTagged(fieldSchema) {
            Some(fieldName)
          } else {
            None
          }
        )
      {tagName, fields: properties, taggedFields}
    })
  | _ => None
  }

// Extract all variant infos from a schema (handles Union and single Object)
let extractAllVariants = (schema: S.t<unknown>): array<variantInfo> =>
  switch schema {
  | Union({anyOf}) => anyOf->Array.filterMap(extractVariantInfo)
  | Object(_) =>
    switch extractVariantInfo(schema) {
    | Some(info) => [info]
    | None => []
    }
  | String({const: ?Some(name)}) =>
    // Single payload-less variant — sury compiles `type t = Foo` to String({const: "Foo"})
    [{tagName: name, fields: Dict.make(), taggedFields: []}]
  | _ => []
  }

// Check if a variant has no payload fields (only TAG)
let isPayloadLess = (info: variantInfo): bool => info.fields->Dict.toArray->Array.length == 0

// Compare two sury schema types for structural compatibility
let rec schemasAreCompatible = (a: S.t<unknown>, b: S.t<unknown>): bool =>
  switch (a, b) {
  | (String(_), String(_)) => true
  | (Number(_), Number(_)) => true
  | (Boolean(_), Boolean(_)) => true
  | (BigInt(_), BigInt(_)) => true
  | (Array({additionalItems: Schema(aItem)}), Array({additionalItems: Schema(bItem)})) =>
    schemasAreCompatible(aItem, bItem)
  | (Union(_), Union(_)) => true
  | (Object(_), Object(_)) => true
  | _ => false
  }

// Get a human-readable type name for a schema
let schemaTypeName = (schema: S.t<unknown>): string =>
  switch schema {
  | String(_) => "string"
  | Number(_) => "float"
  | Boolean(_) => "bool"
  | BigInt(_) => "bigint"
  | Array(_) => "array"
  | Object(_) => "object"
  | Union(_) => "union"
  | Never(_) => "never"
  | Unknown(_) => "unknown"
  | Ref(_) => "ref"
  | _ => "unknown"
  }

type producerEntry = {
  sliceName: string,
  variant: variantInfo,
}

let dedupeKeys = (keys: array<string>): array<string> => {
  let seen = Set.make()
  keys->Array.filter(k =>
    if seen->Set.has(k) {
      false
    } else {
      seen->Set.add(k)
      true
    }
  )
}

/**
Warns when a slice issues a **composite** (multi-tag) decision read for an event
type whose *produced* tag set is a strict superset of the query's tags.

The `tag_composite` GSI key is built from **all** of an event's tags, so a
composite query matches only events tagged *exactly* its query set. An event that
also carries an extra tag is therefore silently missed by the composite read,
while its per-tag fences still move (Issue 5). This commonly bites when a tag is
later added to a multi-tag event without updating the reading slice.

Only all-scalar multi-tag commands build composite reads: a command carrying a
tagged array reads via per-element OR (single-tag) clauses, which cannot hit the
exact-match trap. Returns one `validationError` (warning) per offending
(slice, consumed type) pair.

@param slices `(sliceName, commandSchema, consumedEventSchema)` per consumer.
@param producedTagKeys event type → its produced tag-key set (from the event-log schema).
*/
let validateCompositeReads = (
  ~slices: array<(string, S.t<unknown>, S.t<unknown>)>,
  ~producedTagKeys: dict<array<string>>,
): array<validationError> => {
  let warnings: array<validationError> = []
  slices->Array.forEach(((sliceName, commandSchema, consumedSchema)) =>
    if !DcbTag.hasTaggedArrayFields(commandSchema) {
      let commandTagKeysByVariant = DcbTag.extractTagKeysByEventType(commandSchema)
      let consumedTypes = DcbTag.extractVariantNames(consumedSchema)
      commandTagKeysByVariant
      ->Dict.valuesToArray
      ->Array.forEach(cmdKeys => {
        let querySet = dedupeKeys(cmdKeys)
        if querySet->Array.length >= 2 {
          consumedTypes->Array.forEach(consumedType =>
            switch producedTagKeys->Dict.get(consumedType) {
            | None => ()
            | Some(producedKeys) =>
              let producedSet = dedupeKeys(producedKeys)
              let isSuperset = querySet->Array.every(k => producedSet->Array.includes(k))
              if isSuperset && producedSet->Array.length > querySet->Array.length {
                let extra = producedSet->Array.filter(k => !(querySet->Array.includes(k)))
                let _ = warnings->Array.push({
                  sliceName,
                  message: `composite read on tags [${querySet->Array.join(
                      ", ",
                    )}] will silently miss '${consumedType}', which also carries [${extra->Array.join(
                      ", ",
                    )}] — the tag_composite key includes ALL of an event's tags, so a composite query matches only events tagged exactly [${querySet->Array.join(
                      ", ",
                    )}]. Align the event's tag set with the query, or read '${consumedType}' via a single-tag clause.`,
                })
              }
            }
          )
        }
      })
    }
  )
  warnings
}

let validateProducedAndConsumed = (
  ~produced: array<(string, S.t<unknown>)>,
  ~consumed: array<(string, S.t<unknown>)>,
): result<unit, array<validationError>> => {
  let errors: array<validationError> = []

  // Build a map of TAG name -> array of (sliceName, variantInfo) for produced events
  let producerMap: dict<array<producerEntry>> = Dict.make()
  produced->Array.forEach(((sliceName, schema)) => {
    let variants = extractAllVariants(schema)
    variants->Array.forEach(variant => {
      let existing = producerMap->Dict.get(variant.tagName)->Option.getOr([])
      producerMap->Dict.set(variant.tagName, existing->Array.concat([{sliceName, variant}]))
    })
  })

  // Rule 1: Payload equivalence across producers
  // All producers of the same TAG must have identical fields, types, and tag annotations
  producerMap->Dict.toArray->Array.forEach(((tagName, entries)) => {
    if entries->Array.length > 1 {
      let first = entries->Array.getUnsafe(0)
      let firstFields = first.variant.fields->Dict.keysToArray->Array.toSorted(String.compare)
      let firstTagged = first.variant.taggedFields->Array.toSorted(String.compare)

      entries->Array.forEachWithIndex((entry, idx) => {
        if idx > 0 {
          let entryFields = entry.variant.fields->Dict.keysToArray->Array.toSorted(String.compare)
          let entryTagged = entry.variant.taggedFields->Array.toSorted(String.compare)

          // Check field names match
          if firstFields->Array.length != entryFields->Array.length ||
            firstFields->Array.some(f => !(entryFields->Array.includes(f))) {
            let missingInEntry =
              firstFields->Array.filter(f => !(entryFields->Array.includes(f)))
            let extraInEntry =
              entryFields->Array.filter(f => !(firstFields->Array.includes(f)))
            let parts = []
            if missingInEntry->Array.length > 0 {
              let _ =
                parts->Array.push(
                  `'${first.sliceName}' has fields [${missingInEntry->Array.join(", ")}] which '${entry.sliceName}' is missing`,
                )
            }
            if extraInEntry->Array.length > 0 {
              let _ =
                parts->Array.push(
                  `'${entry.sliceName}' has fields [${extraInEntry->Array.join(", ")}] which '${first.sliceName}' is missing`,
                )
            }
            let _ =
              errors->Array.push({
                sliceName: entry.sliceName,
                message: `Producers '${first.sliceName}' and '${entry.sliceName}' both produce '${tagName}' but with different fields: ${parts->Array.join("; ")}`,
              })
          } else {
            // Fields match by name — check types are compatible
            firstFields->Array.forEach(fieldName => {
              let firstSchema = first.variant.fields->Dict.getUnsafe(fieldName)
              let entrySchema = entry.variant.fields->Dict.getUnsafe(fieldName)
              if !schemasAreCompatible(firstSchema, entrySchema) {
                let _ =
                  errors->Array.push({
                    sliceName: entry.sliceName,
                    message: `Producers '${first.sliceName}' and '${entry.sliceName}' both produce '${tagName}' but field '${fieldName}' has type '${schemaTypeName(firstSchema)}' in '${first.sliceName}' and '${schemaTypeName(entrySchema)}' in '${entry.sliceName}'`,
                  })
              }
            })
          }

          // Check tag annotations match
          if firstTagged->Array.length != entryTagged->Array.length ||
            firstTagged->Array.some(f => !(entryTagged->Array.includes(f))) {
            let untaggedInEntry =
              firstTagged->Array.filter(f => !(entryTagged->Array.includes(f)))
            let untaggedInFirst =
              entryTagged->Array.filter(f => !(firstTagged->Array.includes(f)))
            let parts = []
            if untaggedInEntry->Array.length > 0 {
              let _ =
                parts->Array.push(
                  `[${untaggedInEntry->Array.join(", ")}] tagged in '${first.sliceName}' but not in '${entry.sliceName}'`,
                )
            }
            if untaggedInFirst->Array.length > 0 {
              let _ =
                parts->Array.push(
                  `[${untaggedInFirst->Array.join(", ")}] tagged in '${entry.sliceName}' but not in '${first.sliceName}'`,
                )
            }
            let _ =
              errors->Array.push({
                sliceName: entry.sliceName,
                message: `Producers '${first.sliceName}' and '${entry.sliceName}' both produce '${tagName}' but tag annotations differ: ${parts->Array.join("; ")}`,
              })
          }
        }
      })
    }
  })

  // Rule 2: Every consumed event has a producer
  // Rule 3: Consumed fields exist in produced shape (payload-less always valid)
  // Rule 4: Type compatibility
  consumed->Array.forEach(((sliceName, schema)) => {
    let variants = extractAllVariants(schema)
    variants->Array.forEach(variant => {
      switch producerMap->Dict.get(variant.tagName) {
      | None =>
        let _ =
          errors->Array.push({
            sliceName,
            message: `Slice '${sliceName}' consumes '${variant.tagName}' but no slice produces it`,
          })
      | Some(producers) =>
        // Use first producer as the authoritative shape (Rule 1 ensures they're all identical)
        let producer = producers->Array.getUnsafe(0)

        // Skip field checks for payload-less consumed variants
        if !isPayloadLess(variant) {
          variant.fields->Dict.toArray->Array.forEach(((fieldName, consumedFieldSchema)) => {
            switch producer.variant.fields->Dict.get(fieldName) {
            | None =>
              let _ =
                errors->Array.push({
                  sliceName,
                  message: `Slice '${sliceName}' consumes '${variant.tagName}.${fieldName}' (${schemaTypeName(consumedFieldSchema)}) but produced '${variant.tagName}' has no field '${fieldName}'`,
                })
            | Some(producedFieldSchema) =>
              if !schemasAreCompatible(consumedFieldSchema, producedFieldSchema) {
                let _ =
                  errors->Array.push({
                    sliceName,
                    message: `Slice '${sliceName}' consumes '${variant.tagName}.${fieldName}' as ${schemaTypeName(consumedFieldSchema)} but producer declares it as ${schemaTypeName(producedFieldSchema)}`,
                  })
              }
            }
          })
        }
      }
    })
  })

  if errors->Array.length > 0 {
    Error(errors)
  } else {
    Ok()
  }
}

/**
Validates that DCB tag *scope* (`PartitionScoped` default vs `@crossPartition`)
agrees across every produced event type that carries a given tag key.

The scope is a property of the tag *key*: read routing and — decisively — the
consistency fence are driven by one global per-key flag (the fence is bumped by
*writers*, so a key cannot be cross-partition for one producer and
partition-scoped for another without making the fence ambiguous). This returns
one warning per producer that carries a key some *other* producer declared
`@crossPartition` but this one left partition-scoped.

@param producers `(sliceName, producedEventSchema)` per producing slice.
*/
let validateCrossPartitionScope = (
  ~producers: array<(string, S.t<unknown>)>,
): array<validationError> => {
  let perProducer = producers->Array.map(((name, schema)) => {
    let cpSet = Set.make()
    DcbTag.extractCrossPartitionTagKeys(schema)->Array.forEach(k => cpSet->Set.add(k))
    let carried = Set.make()
    DcbTag.extractTagKeysByEventType(schema)
    ->Dict.valuesToArray
    ->Array.forEach(ks => ks->Array.forEach(k => carried->Set.add(k)))
    (name, cpSet, carried)
  })

  let globalCp = Set.make()
  perProducer->Array.forEach(((_, cpSet, _)) =>
    cpSet->Set.values->Array.fromIterator->Array.forEach(k => globalCp->Set.add(k))
  )

  let warnings: array<validationError> = []
  perProducer->Array.forEach(((name, cpSet, carried)) =>
    carried
    ->Set.values
    ->Array.fromIterator
    ->Array.toSorted((a, b) => String.compare(a, b))
    ->Array.forEach(k =>
      if globalCp->Set.has(k) && !(cpSet->Set.has(k)) {
        let _ = warnings->Array.push({
          sliceName: name,
          message: `tag '${k}' is declared @crossPartition by another producer but is partition-scoped here — DCB tag scope must agree across every event type that carries the tag (read-scope and fence-scope follow one global per-key flag). Add @crossPartition to '${k}' here, or remove it from the other producer.`,
        })
      }
    )
  )
  warnings
}

/** Two-bucket result of validating annotations against the inferred scope. */
type scopeInferenceIssues = {
  /** Annotations that conflict with inference — likely bugs (warn/error). */
  contradictions: array<validationError>,
  /** Annotations inference already derives — safe to delete (info). */
  redundancies: array<validationError>,
}

/**
Validates explicit `@crossPartition` annotations against the *inferred* scope,
now that inference drives the decision-query wiring. Two cases per annotated key:

- **Contradiction** — the key is marked `@crossPartition` on a slice that inference
  resolves as that slice's *own partition*. A slice's own identity is never a
  cross-partition read; the annotation is wrong and (were it to drive the wiring)
  would fan the partition into a spurious secondary read. Surface loudly.
- **Redundant** — the key is marked `@crossPartition` and inference *also* derives
  it as cross-partition from the slice graph. Harmless, but the annotation can be
  dropped — that is the whole point of inference.

@param annotations `(sliceName, @crossPartition keys on the slice's produced event)`.
*/
let validateScopeVsInference = (
  ~annotations: array<(string, array<string>)>,
  ~inferred: DcbScopeInference.derived,
): scopeInferenceIssues => {
  let contradictions: array<validationError> = []
  let redundancies: array<validationError> = []
  annotations->Array.forEach(((name, cpKeys)) =>
    cpKeys->Array.forEach(k =>
      if inferred.partitionBySlice->Dict.get(name) == Some(k) {
        let _ = contradictions->Array.push({
          sliceName: name,
          message: `tag '${k}' is marked @crossPartition but inference resolves it as this slice's own partition key — a slice's own identity is never a cross-partition read. Remove the annotation.`,
        })
      } else if inferred.crossPartitionTagKeys->Array.includes(k) {
        let _ = redundancies->Array.push({
          sliceName: name,
          message: `tag '${k}' is marked @crossPartition but the framework already infers it as a cross-partition read from the slice graph — the annotation is redundant and can be removed.`,
        })
      }
    )
  )
  {contradictions, redundancies}
}
