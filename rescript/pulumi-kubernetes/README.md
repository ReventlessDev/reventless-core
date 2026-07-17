[![npm](https://img.shields.io/npm/v/@reventlessdev/rescript-pulumi-kubernetes.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/rescript-pulumi-kubernetes)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/rescript-pulumi-kubernetes

> ⚠️ **Alpha.** APIs can change without notice between releases.
> Pin exact versions and expect breaking changes.

ReScript bindings for [`@pulumi/kubernetes`](https://www.pulumi.com/registry/packages/kubernetes/api-docs/).

Thin `@module`/`@new` externals over the built-in Kubernetes API groups plus the
generic extension mechanisms, mirroring the style of
[`rescript-pulumi-aws`](../rescript-pulumi-aws).

## Scope

Bindings cover the built-in API groups and the *generic* extension seams:

- **`Provider`** — cluster connection (kubeconfig / context / namespace).
- **`Meta`** — `ObjectMeta` and label/annotation helpers shared by every kind.
- **`Core`** (`core/v1`) — Namespace, Service, ConfigMap, Secret, ServiceAccount,
  PersistentVolumeClaim.
- **`Apps`** (`apps/v1`) — Deployment, StatefulSet (pod/container spec types).
- **`Batch`** (`batch/v1`) — Job, CronJob.
- **`Rbac`** (`rbac.authorization.k8s.io/v1`) — Role, ClusterRole, RoleBinding,
  ClusterRoleBinding.
- **`Networking`** (`networking.k8s.io/v1`) — Ingress, NetworkPolicy.
- **`ApiExtensions`** — `CustomResource` (generic, JSON spec) and
  `CustomResourceDefinition`.
- **`Helm`** — `v3.Release` (operator installs).
- **`Yaml`** — `ConfigFile` / `ConfigGroup` (vendored-manifest escape hatch).

Operator-specific CRD typings are **out of scope** — generate those with
[`crd2pulumi`](https://www.pulumi.com/blog/crd2pulumi/) in your own package,
versioned against the operator versions you pin. `ApiExtensions.CustomResource`
is the escape hatch that makes any custom resource usable without typings.

## Usage

- Add `@reventlessdev/rescript-pulumi-kubernetes` to your dependencies in
  `package.json`.
- Add it to your `dependencies` in `rescript.json`.
- For general information see this monorepo's [readme](../../README.md).

## Example

```rescript
open PulumiKubernetes

let provider = K8s.Provider.make(~name="cluster", ~args={kubeconfig: Pulumi.Input.make(kubeconfig)}, ())

let opts: Pulumi.CustomResourceOptions.t = {provider: provider->K8s.Provider.asProviderResource}

let ns = K8s.Core.Namespace.make(
  ~name="app",
  ~args={metadata: Pulumi.Input.make(K8s.Meta.objectMeta(~name="app", ()))},
  ~opts,
  (),
)
```

Every resource `make` ends with a trailing `()` (it terminates the optional
labelled arguments), and every `args` field takes a `Pulumi.Input.t<_>`, so wrap
plain values with `Pulumi.Input.make`.

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
