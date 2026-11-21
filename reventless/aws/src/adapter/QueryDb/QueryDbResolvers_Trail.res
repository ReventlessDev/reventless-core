// What a lifecycle trail adds to a view's DynamoDB and Postgres resolver sets:
// the `<trail>Entered` field, and the Queries the list door makes on the indexes
// `@trail({index: […]})` derives.
module Resolver = AppSync_Resolver_Retrying

let enteredCode = () => {
  open Reventless.Lifecycle.Trail
  Resolver.Functions.trailEnteredField(
    ~enteredPrefix,
    ~visitsPrefix,
    ~currentAttr=enteredCurrentAttr,
    ~currentKey,
  )
}

/** The `<trail>Entered` field resolver of a view whose trail names a lifecycle. */
let enteredResolver = (
  ~name: string,
  ~api,
  ~dataSourceName,
  ~parentTypeName: string,
  ~stateSchema: option<S.t<unknown>>,
  ~opts,
) =>
  stateSchema
  ->Option.flatMap(s => ReventlessCore.SchemaType.trailEntered(~typeName=parentTypeName, s))
  ->Option.map(({field}) =>
    Resolver.makeUnitJsResolver(
      ~name=name ++ field->String.capitalize,
      ~api,
      ~dataSourceName,
      ~type_=parentTypeName->Pulumi.Input.make,
      ~field=field->Pulumi.Input.make,
      ~code=enteredCode(),
      ~opts,
    )
  )

/**
The list door's Queries on a trail's derived indexes, lifecycle index first: a
request naming the lifecycle keys on it, with the current state's entry as its
sort key; one ranging or ordering by a state's latest entry keys on that state's
index. Anything else stays a Scan.
*/
let keyedReads = (indexes: array<Reventless.ReadModel.indexConfig>): array<
  Resolver.Functions.keyedRead,
> => {
  open Reventless.Lifecycle.Trail
  indexes
  ->Array.filter(Reventless.ReadModel.isDerivedIndex)
  ->Array.filterMap(ic =>
    if ic.index == lifecycleIndexName {
      ic.idField->Option.map((lifecycle): Resolver.Functions.keyedRead => {
        index: ic.index,
        hashAttr: lifecycle,
        hashValue: `_kFilter['${lifecycle}Eq']`,
        hashFilter: lifecycle,
        sortAttr: enteredCurrentAttr,
        sortApi: enteredCurrentName,
        pick: `_has(_kFilter['${lifecycle}Eq'])`,
        tag: "l",
      })
    } else if ic.index->String.startsWith(enteredPrefix) {
      let state = ic.index->String.slice(~start=enteredPrefix->String.length)
      queryNames(state)
      ->Array.get(0)
      ->Option.map(({name}): Resolver.Functions.keyedRead => {
        index: ic.index,
        hashAttr: keyAttr,
        hashValue: `'${keyValue}'`,
        sortAttr: enteredAttr(state),
        sortApi: name,
        pick: `_has(_kFilter['${name}From']) || _has(_kFilter['${name}To']) || !!(_ob && _ob.field === '${name}')`,
        tag: "e" ++ state,
      })
    } else {
      None
    }
  )
}
