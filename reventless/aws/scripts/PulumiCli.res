/***
Reading deployed stacks through the `pulumi` CLI, so a command follows whatever
backend the CLI is logged into.

stderr goes to the caller's terminal: a Pulumi failure is legible where it
happens rather than re-reported here as a vaguer message.
*/

let run = (~cwd: string, args: array<string>): string =>
  NodeChildProcess.execFileSync(
    "pulumi",
    args->Array.concat(["--cwd", cwd, "--non-interactive"]),
    {encoding: "utf8", stdio: ["ignore", "pipe", "inherit"], maxBuffer: 64 * 1024 * 1024},
  )->String.trim

/** Whether the project in `dir` keeps settings for `stack` — how the deploy
    workflow tells a stack that was never deployed from one that was. */
let hasStackFile = (~dir: string, ~stack: string): bool =>
  NodeFs.existsSync(NodePath.join([dir, `Pulumi.${stack}.yaml`]))

let stackOutputs = (~dir: string, ~stack: string): result<dict<JSON.t>, string> =>
  switch run(~cwd=dir, ["stack", "output", "--json", "--stack", stack]) {
  | text =>
    switch text->JSON.parseOrThrow->JSON.Decode.object {
    | Some(outputs) => Ok(outputs)
    | None => Error(`stack "${stack}" in ${dir} returned outputs that are not an object`)
    | exception _ => Error(`stack "${stack}" in ${dir} returned outputs that are not JSON`)
    }
  | exception _ => Error(`could not read the outputs of stack "${stack}" in ${dir}`)
  }

let selectedStack = (~dir: string): option<string> =>
  switch run(~cwd=dir, ["stack", "--show-name"]) {
  | "" => None
  | name => Some(name)
  | exception _ => None
  }

let stringOutput = (outputs: dict<JSON.t>, name: string): option<string> =>
  switch outputs->Dict.get(name)->Option.flatMap(JSON.Decode.string) {
  | Some("") | None => None
  | value => value
  }
