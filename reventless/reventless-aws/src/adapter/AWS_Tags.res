let make = (~name, componentType) =>
  [
    ("Name", name),
    ("Type", componentType->ReventlessCore.ComponentType.toString),
    ("Environment", Pulumi.Pulumi.getStackName()),
    ("Plugin", Pulumi.Pulumi.getProjectName()),
  ]
  ->Dict.fromArray
  ->Pulumi.Input.make
