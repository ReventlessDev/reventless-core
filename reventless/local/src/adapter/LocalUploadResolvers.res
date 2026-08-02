// Local upload resolver logic (route B), backed by `LocalObjectStore`. Shared by the
// dev platform (`Platform.res` registers these on the domain server) and
// `ServedBucketHttpTest`, so the mint/release behaviour has one definition.
//
// The dev store has no identities and no clock, so release enforces only the *shape*
// of the rule (key under a served prefix), not the identity/age conditions AWS applies
// — dev parity is about the client seeing the same contract, not reproducing AWS's
// guarantees. See [docs/plans/done/upload-release-path.md] § Step 3.

// Mint a same-origin `/{prefix}/{uuid}/{fileName}` ref: both the PUT target and the
// stored value, mirroring the AWS presign ticket's shape.
let mintRef = (~fileName: string): string =>
  `/${LocalObjectStore.defaultUploadPrefix}/${NodeCrypto.randomUUID()}/${fileName}`

// Release a ref: delete iff it sits under a served prefix; idempotent (deleting an
// absent key still succeeds). Returns `(released, reason)`.
let release = (~storageRef: string): (bool, option<string>) =>
  switch LocalObjectStore.servedKey(storageRef) {
  | Some(key) =>
    LocalObjectStore.delete(~key)
    (true, None)
  | None => (false, Some("not_in_store"))
  }

// Register `Upload_Presign` / `Upload_Release` (types + mutation fields + resolvers) on
// a GraphQL server instance — the local analogue of adding them to `domainBaseFragment`.
let register = (server: ReventlessGraphqlServer.GraphQL_ServerInstance.t): unit => {
  let resolvers = Dict.make()
  resolvers->Dict.set("Upload_Presign", async (_root, args, _ctx): JSON.t => {
    let obj = args->JSON.Decode.object->Option.getOr(Dict.make())
    let fileName =
      obj->Dict.get("fileName")->Option.flatMap(JSON.Decode.string)->Option.getOr("upload")
    let ref = mintRef(~fileName)
    Dict.fromArray([
      ("uploadUrl", JSON.Encode.string(ref)),
      ("storageRef", JSON.Encode.string(ref)),
    ])->JSON.Encode.object
  })
  resolvers->Dict.set("Upload_Release", async (_root, args, _ctx): JSON.t => {
    let obj = args->JSON.Decode.object->Option.getOr(Dict.make())
    let storageRef =
      obj->Dict.get("storageRef")->Option.flatMap(JSON.Decode.string)->Option.getOr("")
    let (released, reason) = release(~storageRef)
    Dict.fromArray([
      ("released", JSON.Encode.bool(released)),
      ("reason", reason->Option.mapOr(JSON.Null, JSON.Encode.string)),
    ])->JSON.Encode.object
  })
  server.registerTypes(~sdlTypes=ReventlessCore.Platform_AdminApi.uploadTypes)
  server.registerMutations(
    ~sdlFields=ReventlessCore.Platform_AdminApi.uploadMutationFields,
    ~resolvers,
  )
}
