module type T = {
  type api;
  type role;
  type userPool;

  let api: api;
  let apiRole: role;
  let userPool: userPool;

  let atomicCounter: AtomicCounter.t;
  let scheduler: Scheduler.t;
};