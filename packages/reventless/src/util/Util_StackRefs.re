let stackRefs: Js.Dict.t(Pulumi.StackReference.t) = Js.Dict.empty();

let coreStackName =
  Pulumi.Config.make(Some("core"))->Pulumi.Config.get("stack");

let stackName = pluginName =>
  coreStackName->Belt.Option.map(name => {
    let parts = name->Js.String2.split("/");
    let _ = parts->Belt.Array.set(1, pluginName);
    parts->Js.Array2.joinWith("/");
  });

let get = pluginName => {
  switch (stackRefs->Js.Dict.get(pluginName)) {
  | None =>
    let stackRef =
      pluginName
      ->stackName
      ->Belt.Option.map(stack => stack->Pulumi.StackReference.make);

    switch (stackRef) {
    | Some(stackRef) =>
      let _ = stackRefs->Js.Dict.set(pluginName, stackRef);
      Some(stackRef);
    | None => None
    };
  | stackRef => stackRef
  };
};
