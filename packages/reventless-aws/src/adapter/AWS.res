let tags = (~name, componentType) =>
  [
    ("Name", name),
    ("Type", componentType->Reventless.ComponentType.toString),
    ("Environment", Pulumi.Pulumi.getStackName()),
    ("Plugin", Pulumi.Pulumi.getProjectName()),
  ]
  ->Js.Dict.fromArray
  ->Pulumi.Input.make
