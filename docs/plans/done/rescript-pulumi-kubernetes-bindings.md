# Plan: `rescript-pulumi-kubernetes` (+ `rescript-pulumi-docker-build`) bindings

**Status**: Implemented (2026-07-04) — phases A1–B2 complete and building with
zero warnings; the mock-mode smoke test passes. B3 (publish) is left to the
user-initiated release train.
**Nature**: feature plan. Two new published bindings packages under
`rescript/`: `@reventlessdev/rescript-pulumi-kubernetes` (externals over
`@pulumi/kubernetes`) and the much smaller
`@reventlessdev/rescript-pulumi-docker-build` (externals over
`@pulumi/docker-build`). Apache-2.0, style and layout of
`rescript/rescript-pulumi-aws`. No framework-package changes.

## Motivation

Pulumi is the framework's deploy-time execution model (`Adapter.resource`
threads `Pulumi.Output.t` through every signature; `Runtime.Environment.make`
takes `Pulumi.ComponentResource.options`). Runtime backends targeting
Kubernetes therefore need typed ReScript access to `@pulumi/kubernetes` the
same way `reventless-aws` uses `rescript-pulumi-aws`. Both providers are
first-party and schema-generated; the bindings are mechanical externals with
no logic. Publishing them as generic OSS bindings also serves any ReScript
user deploying to Kubernetes with Pulumi, independent of this framework —
the same posture as every other `rescript/*` package.

## Scope principle: generic only

Bind the built-in Kubernetes API groups plus the *generic* extension
mechanisms. Do **not** bind operator-specific CRDs (KEDA, CloudNativePG,
NATS, cert-manager, …): consumers generate those with `crd2pulumi` in their
own packages, versioned against the operator versions *they* pin. The
`apiextensions.CustomResource` binding is the escape hatch that makes any CR
usable without typings; typed CRs are a consumer-side quality upgrade, not a
core concern. This keeps the package stable — it changes only when
`@pulumi/kubernetes` itself does.

## Package layout (mirrors `rescript-pulumi-aws`'s per-service directories)

```
rescript/rescript-pulumi-kubernetes/src/
├── K8s.res                    # provider: Provider.make(~kubeconfig, ~namespace=?, ...),
│                              # invoke options, server-side-apply toggles
├── Meta/                      # ObjectMeta, labels/annotations helpers, types shared by all kinds
├── Core/                      # v1: Namespace, Service, ConfigMap, Secret, ServiceAccount,
│                              # PersistentVolumeClaim
├── Apps/                      # v1: Deployment, StatefulSet (pod-template types live here)
├── Batch/                     # v1: Job, CronJob
├── Rbac/                      # v1: Role, ClusterRole, RoleBinding, ClusterRoleBinding
├── Networking/                # v1: Ingress, NetworkPolicy
├── ApiExtensions/             # CustomResource (generic, JSON spec), CustomResourceDefinition
├── Helm/                      # v3/v4 Release (operator installs)
└── Yaml/                      # ConfigFile/ConfigGroup (vendored-manifest escape hatch)

rescript/rescript-pulumi-docker-build/src/
└── DockerBuild.res            # Image.make(~context, ~dockerfile=?, ~platforms=?, ~push, ~registries)
```

Binding style: thin `@module`/`@new` externals + labeled-argument `make`
wrappers returning the resource handle, exactly as
`rescript-pulumi-aws/src/DynamoDb`/`Lambda` do. Pod/container spec types are
the one genuinely large surface — bind the fields consumers actually set
(image, command, env, envFrom, resources, probes, volumes/mounts,
serviceAccountName, terminationGracePeriodSeconds, nodeSelector,
tolerations, affinity as opaque JSON initially) and leave an
`...rest: JSON.t`-style passthrough for the long tail rather than
transcribing the entire OpenAPI schema.

## Phasing

| Phase | Item | Class | Status |
|---|---|---|---|
| A1 | Package scaffold + `Provider` + `Meta` + `Core` (Namespace, ConfigMap, Secret, Service, ServiceAccount, PVC) | Plumbing | ✅ done |
| A2 | `Apps` (Deployment incl. pod/container spec types) + `Batch` (Job, CronJob) | Feature (largest item) | ✅ done |
| A3 | `Rbac` + `Networking` | Feature | ✅ done |
| A4 | `ApiExtensions.CustomResource` (+ `CustomResourceDefinition`) + `Helm.Release` + `Yaml` | Feature (the extension seams) | ✅ done |
| B1 | `rescript-pulumi-docker-build` package | Feature (small) | ✅ done |
| B2 | Mock-mode smoke test: a tiny Pulumi program (Deployment + CronJob + CustomResource + Helm Release) compiled and run under Pulumi mocks, asserting emitted resource shapes | Test | ✅ done (5/5 pass) |
| B3 | Publish both packages on the regular release train | Release | ⏳ pending user-initiated release |

### Implementation notes / deviations

- **Pod/container spec types live in `Core` (`Core_Pod.res`), not `Apps`.** They
  are genuinely `core/v1` types shared by every workload kind, so both `Apps`
  and `Batch` reference `Core.Pod.*` rather than duplicating them. (The plan
  sketched them under `Apps`; `Core` is the more accurate home and avoids an
  Apps→Batch coupling.)
- **`make` externals take a trailing `unit`** (`make(~name, ~args, ())`), the
  idiomatic ReScript shape for all-optional trailing labelled args. This lets
  consumers omit `~opts` and still fully apply — friendlier than the
  `rescript-pulumi-aws` style that forces `~opts?` at every call site.
- **Long-tail passthrough** is `JSON.t` on the fields most likely to need it
  (`affinity`, `securityContext`, CRD `spec`, ClusterRole `aggregationRule`),
  plus `ApiExtensions.CustomResource.makeRaw(~args: JSON.t)` as the fully-generic
  escape hatch. Coverage grows additively.
- **Smoke test runs under Node's built-in test runner**, not jest: importing the
  full `@pulumi/pulumi` runtime pulls in `@pulumi/pulumi/automation`, whose
  transitive `spdx-*` deps jest's resolver can't follow through pnpm's symlinked
  `node_modules`. Node resolves them natively.
- **`crd2pulumi` compatibility (risk #3)** is exercised in principle by the
  generic `CustomResource` test (untyped apiVersion/kind/spec round-trips
  cleanly); binding a real generated CR class is left to consumers.

## Non-goals

- Operator/CRD typings (consumer-side `crd2pulumi`, see scope principle).
- Full OpenAPI-complete pod-spec transcription (passthrough covers the tail;
  extend field coverage on demand).
- `kustomize` support, alpha API groups, and `@pulumi/kubernetes`'
  auto-naming edge cases beyond what the smoke test exercises.
- Any framework integration — runtime backends consuming these bindings are
  their own packages/plans.

## Risks / open questions

- **Helm v3 (`helm.sh/v3.Release`) vs v4 (`helm/v4.Chart`)**: bind v3
  `Release` first (stable, imperative-install semantics consumers expect);
  evaluate v4 once its API settles. Cheap to add later, confusing to offer
  both untested now.
- **Pod-spec field coverage** will grow by consumer demand; keep additions
  additive and document the JSON passthrough as the supported escape hatch
  so missing fields never block anyone.
- **`crd2pulumi` output compatibility**: consumers' generated CR classes
  subclass `@pulumi/kubernetes` internals; the generic `CustomResource`
  binding must not assume otherwise (verify in B2 with one generated CR).
