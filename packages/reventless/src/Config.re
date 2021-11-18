module type T = {
  type api;
  type role;
  type userPool;

  let pluginName: string;

  let api: api;
  let apiRole: role;
  let userPool: userPool;

  let scheduler: Scheduler.t;
};
