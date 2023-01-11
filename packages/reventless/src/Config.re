module type T = {
  type api;
  type role;
  type userPool;

  let pluginName: string;

  let api: api;
  let apiRole: role;
  let userPoolId: Pulumi.Output.t(string);

  let scheduler: Scheduler.t;
};
