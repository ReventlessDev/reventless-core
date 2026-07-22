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
  // The model element that owns this resource. Overrides `~kind`, `~component`
  // and `~scope`: the piece adapters pass their own ComponentType as `~kind`,
  // which names the PIECE, so it collapses onto `~role` whenever the owner is
  // unknown. Supplied by the owning builder via `ResourceAttribution.owner` —
  // see docs/plans/done/resource-attribution-owner-kind.md.
  //
  // A plugin is a model element too, so shared substrate (a DcbEventLog, a
  // plugin's DCB command topics, its event collector) is owned by the Plugin
  // rather than by nothing — that is how it gets attributed to the element it
  // actually belongs to. `Plugin`-kinded owners therefore imply plugin scope,
  // where `reventless:plugin` names the owner and `reventless:component` is
  // empty by definition.
  ~owner: option<Attribution.owner>=?,
  ~plugin: option<string>=?,
  ~platform: option<string>=?,
) => {
  let ambient = Attribution.current.contents
  let projectName = Pulumi.Pulumi.getProjectName()

  let platform = switch platform {
  | Some(p) => p
  | None => ambient.platform->Option.getOr(projectName)
  }

  let kind = switch owner {
  | Some({kind}) => kind
  | None => kind
  }

  // A Plugin-kinded owner IS the plugin, so the resource is plugin substrate
  // whatever default scope the piece adapter passed.
  let scope = switch owner {
  | Some({kind: Plugin}) => Attribution.Scope.Plugin
  | Some(_) | None => scope
  }

  let plugin = switch scope {
  | Platform => ""
  | Component | Plugin =>
    switch (plugin, owner) {
    | (Some(p), _) => p
    | (None, Some({kind: Plugin, name})) => name
    | (None, _) => ambient.plugin->Option.getOr("")
    }
  }

  let component = switch scope {
  | Component =>
    switch owner {
    | Some({name}) => name
    | None => component->Option.getOr(name)
    }
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

/***
Framework-created AWS resource types that carry NO attribution tags, and why.
Keep this list here rather than in a plan: it is what tells a coverage audit
whether a bare resource is a gap to close or a fact to work around.

**Cannot be tagged** — the provider type exposes no `tags` property at all
(verified against `@pulumi/aws` 7.19.0; re-verify on a major provider bump, since
AWS does add tag support over time — `lambda/eventSourceMapping` gained it after
the first sweep and is now tagged):

    aws:appsync/dataSource        aws:appsync/resolver (incl. aws-native)
    aws:appsync/function          aws:appsync/sourceApiAssociation
    aws:iam/rolePolicy            aws:iam/rolePolicyAttachment
    aws:sqs/queuePolicy           aws:sns/topicSubscription
    aws:lambda/permission         aws:lambda/invocation
    aws:cloudwatch/logMetricFilter aws:cloudwatch/eventTarget
    aws:s3/bucketPolicy           aws:s3/bucketPublicAccessBlock
    aws:cloudfront/originAccessControl
    aws:cognito/userPoolClient    aws:cognito/userGroup
    aws:route53/record            aws:acm/certificateValidation
    aws:ses/emailIdentity         aws:ses/identityPolicy

Each is attributable only through its parent (function, log group, API, role,
bucket, pool, certificate) — i.e. structurally, by URN ancestry. A consumer that
treats "carries `reventless:*` tags" as universal will be wrong about every row
above, and no amount of coverage work changes that. Note the ReScript binding for
`IAM.RolePolicy` carries a `tags?` field that AWS ignores; do not read its
presence as tag support.

**Taggable, deliberately untagged** — `aws:s3/bucketObject`. Static-bundle assets
are bucket *contents*, not infrastructure: they are fully attributed by the
bucket that holds them, and S3 bills object tags per object per month, so tagging
a few hundred bundle files would cost money to restate a fact the parent already
carries.
*/

/**
The same schema as `makeDict`, wrapped as a Pulumi input — what nearly every
resource's `tags` field expects. Use `makeDict` only for the bindings that take
raw tags because they post-process them (e.g. `EC2.Vpc`, which supplements a
`Name` of its own).
*/
let make = (
  ~name,
  ~kind,
  ~role,
  ~scope=Attribution.Scope.Component,
  ~component=?,
  ~owner=?,
  ~plugin=?,
  ~platform=?,
) =>
  makeDict(
    ~name,
    ~kind,
    ~role,
    ~scope,
    ~component?,
    ~owner?,
    ~plugin?,
    ~platform?,
  )->Pulumi.Input.make
