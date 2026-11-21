// The `<trail>Entered` field resolver of a view whose trail names a lifecycle,
// shared by the DynamoDB and the Postgres resolver sets.
module Resolver = AppSync_Resolver_Retrying

let code = () => {
  open Reventless.Lifecycle.Trail
  Resolver.Functions.trailEnteredField(
    ~enteredPrefix,
    ~visitsPrefix,
    ~currentAttr=enteredCurrentAttr,
    ~currentKey,
  )
}

let make = (
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
      ~code=code(),
      ~opts,
    )
  )
