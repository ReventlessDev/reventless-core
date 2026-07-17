/** @pulumi/docker-build Image — a BuildKit-built, optionally multi-platform,
  optionally-pushed Docker image.
  see: https://www.pulumi.com/registry/packages/docker-build/api-docs/image/
*/

/** Target build platform. Common values are bound; for anything else construct
  the string with `Obj.magic` (the underlying type is a plain string enum). */
type platform =
  | @as("linux/amd64") LinuxAmd64
  | @as("linux/arm64") LinuxArm64
  | @as("linux/arm") LinuxArm
  | @as("linux/386") Linux386
  | @as("linux/ppc64le") LinuxPpc64le
  | @as("linux/s390x") LinuxS390x
  | @as("darwin/amd64") DarwinAmd64
  | @as("darwin/arm64") DarwinArm64
  | @as("windows/amd64") WindowsAmd64

type buildContext = {
  /** Build context: a local path, a Git URL, or a tarball URL. */
  location: string,
}

/** Exactly one of `location` / `inline` is set. */
type dockerfile = {
  location?: string,
  inline?: string,
}

type registry = {
  /** Registry host, e.g. `"docker.io"` or `"123.dkr.ecr.eu-west-1.amazonaws.com"`. */
  address: string,
  username?: string,
  password?: string,
}

type t = {
  id: Pulumi.Output.t<string>,
  /** Pushed image reference including digest, when `push` is true. */
  ref: Pulumi.Output.t<string>,
  digest: Pulumi.Output.t<string>,
  contextHash: Pulumi.Output.t<string>,
}

type args = {
  /** Only `push` is required; a build with no context/dockerfile builds the
    current directory's `Dockerfile`. */
  push: Pulumi.Input.t<bool>,
  context?: Pulumi.Input.t<buildContext>,
  dockerfile?: Pulumi.Input.t<dockerfile>,
  tags?: Pulumi.Input.t<array<string>>,
  platforms?: Pulumi.Input.t<array<platform>>,
  registries?: Pulumi.Input.t<array<registry>>,
  buildArgs?: Pulumi.Input.t<dict<string>>,
  labels?: Pulumi.Input.t<dict<string>>,
  target?: Pulumi.Input.t<string>,
  noCache?: Pulumi.Input.t<bool>,
  pull?: Pulumi.Input.t<bool>,
  /** Load the built image into the local Docker daemon. */
  load?: Pulumi.Input.t<bool>,
  /** Build networking mode, e.g. `"default"`, `"host"`, `"none"`. */
  network?: Pulumi.Input.t<string>,
  /** Build during `pulumi preview` as well as `up`. */
  buildOnPreview?: Pulumi.Input.t<bool>,
}

@module("@pulumi/docker-build") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?, unit) => t = "Image"
