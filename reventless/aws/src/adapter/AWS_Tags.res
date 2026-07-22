module Attribution = ReventlessCore.ResourceAttribution

/**
Attribution tags for a framework-created AWS resource.

Every framework fact is namespaced `reventless:*`, lower-case, and appears
exactly once. `Name` is the single bare key, and it is earned: the AWS console
reads that literal spelling to populate the resource-name column, so namespacing
it would leave the column blank. Everything else — including the environment —
is a framework fact and carries the namespace. AWS cost allocation groups by any
activated tag key, so `reventless:environment` is a first-class cost-allocation
dimension; the bare spelling bought nothing.

The three attribution facts are independent and all three are needed to identify
a resource (see `ResourceAttribution`):

- `~kind` — the modelling kind of the owning component (Aggregate, …)
- `~role` — the deployment piece this resource implements (EventLog, Runtime, …)
- `~scope` — component / plugin / platform

`~plugin` and `~platform` default to the ambient context published by
`Plugin_Builder` while a plugin is under construction, falling back to the Pulumi
project name for platform-scope resources built outside any plugin. Note the
project name is what the framework already calls the *platform* name
(`Plugin_Builder.Spec.platformName`) — attributing it to `reventless:plugin`, as
this helper used to, mislabelled every resource.

Non-component scopes carry an empty `reventless:component` by definition:
substrate is attributed to its level, not to a fabricated component.
*/
let makeDict = (
  ~name: string,
  ~kind: ReventlessCore.ComponentType.t,
  ~role: Attribution.Role.t,
  ~scope: Attribution.Scope.t=Component,
  // The model component stem, when it differs from the resource name
  // ("Products" for a resource named "ProductsQueryDb"). Defaults to `~name`.
  ~component: option<string>=?,
  ~plugin: option<string>=?,
  ~platform: option<string>=?,
) => {
  let ambient = Attribution.current.contents
  let projectName = Pulumi.Pulumi.getProjectName()

  let platform = switch platform {
  | Some(p) => p
  | None => ambient.platform->Option.getOr(projectName)
  }

  let plugin = switch scope {
  | Platform => ""
  | Component | Plugin =>
    switch plugin {
    | Some(p) => p
    | None => ambient.plugin->Option.getOr("")
    }
  }

  let component = switch scope {
  | Component => component->Option.getOr(name)
  | Plugin | Platform => ""
  }

  [
    ("Name", name),
    ("reventless:platform", platform),
    ("reventless:plugin", plugin),
    ("reventless:component", component),
    ("reventless:kind", kind->ReventlessCore.ComponentType.toString),
    ("reventless:role", role->Attribution.Role.toString),
    ("reventless:scope", scope->Attribution.Scope.toString),
    ("reventless:environment", Pulumi.Pulumi.getStackName()),
  ]->Dict.fromArray
}

/**
The same schema as `makeDict`, wrapped as a Pulumi input — what nearly every
resource's `tags` field expects. Use `makeDict` only for the bindings that take
raw tags because they post-process them (e.g. `EC2.Vpc`, which supplements a
`Name` of its own).
*/
let make = (~name, ~kind, ~role, ~scope=Attribution.Scope.Component, ~component=?, ~plugin=?, ~platform=?) =>
  makeDict(~name, ~kind, ~role, ~scope, ~component?, ~plugin?, ~platform?)->Pulumi.Input.make
