let make = (~name, componentType) => {
  let plugin = Pulumi.Pulumi.getProjectName()
  let kind = componentType->ReventlessCore.ComponentType.toString
  [
    ("Name", name),
    ("Type", kind),
    ("Environment", Pulumi.Pulumi.getStackName()),
    ("Plugin", plugin),
    ("reventless:plugin", plugin),
    ("reventless:component", name),
    ("reventless:role", kind),
    ("reventless:kind", kind),
  ]
  ->Dict.fromArray
  ->Pulumi.Input.make
}
