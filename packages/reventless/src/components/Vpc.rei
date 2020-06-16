type outputs = {. "vpc": string};
type t = outputs;

let make:
  (~name: string, ~opts: Pulumi.ComponentResource.Options.t=?, unit) => t;
