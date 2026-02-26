let stackRefs: dict<Pulumi.StackReference.t> = Dict.make()

let coreStackName = Pulumi.Config.make(Some("core"))->Pulumi.Config.get("stack")

let stackName = pluginName =>
  coreStackName->Option.map(name => {
    let parts = name->String.split("/")
    parts->Array.set(1, pluginName)
    parts->Array.joinUnsafe("/")
  })

let get = pluginName =>
  switch stackRefs->Dict.get(pluginName) {
  | None =>
    let stackRef = pluginName->stackName->Option.map(stack => stack->Pulumi.StackReference.make)

    switch stackRef {
    | Some(stackRef) =>
      stackRefs->Dict.set(pluginName, stackRef)
      Some(stackRef)
    | None => None
    }
  | stackRef => stackRef
  }
