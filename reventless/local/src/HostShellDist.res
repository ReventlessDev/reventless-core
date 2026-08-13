// Where the local host shell serves its static assets from.
//
// Locally there is no deploy and no bucket: `reventless-host-shell` serves its
// own `dist/` (that is where the shipped `config.json` and `ui-hints.json` a dev
// sees come from), so that is where every generated asset the browser fetches
// has to land — the baked component manifest and the `config.json` overlay
// alike. Resolved in one place because those writers have to agree: a second
// opinion about the directory puts a manifest where nothing reads it, and the
// symptom is an empty shell rather than a missing file.
//
// Resolved from the running project rather than from this framework module: the
// bundle is a deploy input the project names in its own package.json, and a
// framework-rooted lookup would skip that pin (the same distinction
// `Util_Bundle.resolvePackageRoot(~fromPulumiProject)` draws on AWS).

let package = "@reventlessdev/reventless-host-shell"

let dir = (): option<string> =>
  try {
    Some(
      NodePath.dirname(
        NodeModule.createRequire(NodeProcess.cwd() ++ "/index.js")->NodeModule.requireResolve(
          package ++ "/package.json",
        ),
      ) ++ "/dist",
    )
  } catch {
  | _ => None
  }
