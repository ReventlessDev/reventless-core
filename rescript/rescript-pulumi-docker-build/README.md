[![npm version](https://img.shields.io/npm/v/@reventlessdev/rescript-pulumi-docker-build.svg?label=version)](https://www.npmjs.com/package/@reventlessdev/rescript-pulumi-docker-build)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

# `rescript-pulumi-docker-build`

ReScript bindings for [`@pulumi/docker-build`](https://www.pulumi.com/registry/packages/docker-build/api-docs/),
the BuildKit-based Docker image builder for Pulumi.

Thin `@module`/`@new` externals over the single `Image` resource, mirroring the
style of [`rescript-pulumi-aws`](../rescript-pulumi-aws).

## Usage

- Add `@reventlessdev/rescript-pulumi-docker-build` to your dependencies in
  `package.json`.
- Add it to your `bs-dependencies` in `rescript.json`.

## Example

```rescript
let image = DockerBuild.Image.make(
  ~name="app",
  ~args={
    push: Pulumi.Input.make(true),
    context: Pulumi.Input.make({location: "./app"}),
    tags: Pulumi.Input.make(["registry.example.com/app:latest"]),
    platforms: Pulumi.Input.make([DockerBuild.Image.LinuxAmd64, DockerBuild.Image.LinuxArm64]),
  },
  (),
)
```

Only `push` is required. Each `args` field takes a `Pulumi.Input.t<_>`, so wrap
plain values with `Pulumi.Input.make`, and terminate the call with `()`.
