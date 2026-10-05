/***
An app's `deploy-manifest.yaml`: the folder holding the platform stack, and the
folders holding the plugin stacks, in the order they deploy.

The reusable deploy workflow reads it with `yq`; the commands in this folder read
it here. Paths in the file are relative to the file's own folder.

`stack-defaults` on an entry are the settings `deploy-app` gives a stack it
creates for that folder — what a new stack of this app cannot deploy without.
A plugin's `region` overrides the file's for that stack; `review: false` keeps it
out of a pull request's review environment.
*/

@module("yaml") external parseYaml: string => JSON.t = "parse"

@schema
type platform = {
  path: string,
  name?: string,
  @as("stack-defaults") stackDefaults?: dict<string>,
}

@schema
type plugin = {
  name: string,
  path: string,
  @as("depends-on") dependsOn?: array<string>,
  @as("stack-defaults") stackDefaults?: dict<string>,
  region?: string,
  review?: bool,
}

@schema
type t = {
  region?: string,
  platform: platform,
  plugins?: array<plugin>,
}

/** One stack folder, with its path made absolute. */
type project = {
  name: string,
  dir: string,
  stackDefaults: dict<string>,
  region: option<string>,
  /** Whether a review environment deploys it: false only on a plugin marked so. */
  review: bool,
}

type resolved = {
  file: string,
  region: option<string>,
  platform: project,
  plugins: array<project>,
}

let defaultFile = "deploy-manifest.yaml"

let parseString = (text: string): result<t, string> =>
  try Ok(S.parseOrThrow(parseYaml(text), ~to=schema)) catch {
  | JsExn(err) => Error(JsExn.message(err)->Option.getOr("not a deploy manifest"))
  | _ => Error("not a deploy manifest")
  }

let resolve = (manifest: t, ~file: string): resolved => {
  let base = NodePath.dirname(NodePath.resolve([file]))
  {
    file,
    region: manifest.region,
    platform: {
      name: manifest.platform.name->Option.getOr("platform"),
      dir: NodePath.resolve([base, manifest.platform.path]),
      stackDefaults: manifest.platform.stackDefaults->Option.getOr(Dict.make()),
      region: None,
      review: true,
    },
    plugins: manifest.plugins
    ->Option.getOr([])
    ->Array.map(p => {
      name: p.name,
      dir: NodePath.resolve([base, p.path]),
      stackDefaults: p.stackDefaults->Option.getOr(Dict.make()),
      region: p.region,
      review: p.review->Option.getOr(true),
    }),
  }
}

let load = (file: string): result<resolved, string> =>
  switch try Ok(NodeFs.readFileSync(file)) catch {
  | _ => Error(`cannot read ${file}`)
  } {
  | Error(_) as e => e
  | Ok(text) =>
    switch parseString(text) {
    | Error(message) => Error(`${file}: ${message}`)
    | Ok(manifest) => Ok(manifest->resolve(~file))
    }
  }
