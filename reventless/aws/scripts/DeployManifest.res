/***
An app's `deploy-manifest.yaml`: the folder holding the platform stack, and the
folders holding the plugin stacks, in the order they deploy.

The reusable deploy workflow reads it with `yq`; the commands in this folder read
it here. Paths in the file are relative to the file's own folder.
*/

@module("yaml") external parseYaml: string => JSON.t = "parse"

@schema
type platform = {path: string, name?: string}

@schema
type plugin = {
  name: string,
  path: string,
  @as("depends-on") dependsOn?: array<string>,
}

@schema
type t = {
  region?: string,
  platform: platform,
  plugins?: array<plugin>,
}

type pluginDir = {name: string, dir: string}

/** The manifest with every path made absolute. */
type resolved = {
  file: string,
  region: option<string>,
  platformDir: string,
  plugins: array<pluginDir>,
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
    platformDir: NodePath.resolve([base, manifest.platform.path]),
    plugins: manifest.plugins
    ->Option.getOr([])
    ->Array.map(p => {name: p.name, dir: NodePath.resolve([base, p.path])}),
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
