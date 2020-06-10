let find: (array('a), string) => option('a) =
  (resources, name) =>
    resources->Belt.Array.reduce(None, (result, resource) =>
      resource##name == name ? Some(resource) : result
    );

let allServicesOfContext: Context.t => array(Service.t) =
  context => context##services;

let serviceOfContext: (Context.t, string) => option(Service.t) =
  (context, serviceName) => context##services->find(serviceName);

let allServicesOfAllContexts: array(Context.t) => array(Service.t) =
  contexts =>
    contexts
    ->Belt.Array.map(context => context->allServicesOfContext)
    ->Belt.Array.concatMany;

let serviceOfAllContexts: (array(Context.t), string) => option(Service.t) =
  (contexts, serviceName) =>
    contexts
    ->Belt.Array.map(context => context->serviceOfContext(serviceName))
    ->Belt.Array.reduce(None, (result, resource) =>
        switch (result, resource) {
        | (_, Some(_) as r) => r
        | (r, None) => r
        }
      );

let aggregateOfAllContexts = (contexts, serviceName) =>
  contexts
  ->serviceOfAllContexts(serviceName)
  ->Belt.Option.map(service => service##aggregate);

let eventTopicPublisherOfAllContexts:
  (array(Context.t), string) => option(Adapter.resource) =
  (contexts, serviceName) => {
    contexts
    ->aggregateOfAllContexts(serviceName)
    ->Belt.Option.map(aggregate => aggregate##eventTopic##publisher);
  };

let eventTopicPublisherOfAllContextsExn = (contexts, serviceName) =>
  eventTopicPublisherOfAllContexts(contexts, serviceName)
  ->ResourceQuery.unwrapResource("EventTopic", serviceName);

let readModelOfService: Service.t => ReadModel.outputs =
  service => service##readModel;

let queryDbOfReadModel: ReadModel.outputs => QueryDb.outputs =
  readModel => readModel##queryDb;

let queryDbOfService: Service.t => QueryDb.outputs =
  service => service->readModelOfService->queryDbOfReadModel;

let allResolversMakers: array(Context.t) => array(QueryDb.resolversMaker) =
  contexts =>
    contexts
    ->allServicesOfAllContexts
    ->Belt.Array.map(queryDbOfService)
    ->Belt.Array.map(queryDb => queryDb##resolversMaker);

let allEventLogStorages: array(Context.t) => array(Adapter.resource) =
  contexts =>
    contexts
    ->allServicesOfAllContexts
    ->Belt.Array.map(service => service##aggregate##eventLog##storage);

let allQueryDbStorages: array(Context.t) => array(Adapter.resource) =
  contexts =>
    contexts
    ->allServicesOfAllContexts
    ->Belt.Array.map(service => service##readModel##queryDb##storage);

let queryDbStorageOfService: Service.t => Adapter.resource =
  service => service->queryDbOfService##storage;

let queryDbStorageOfAllContexts:
  (array(Context.t), string) => option(Adapter.resource) =
  (contexts, serviceName) =>
    contexts
    ->serviceOfAllContexts(serviceName)
    ->Belt.Option.map(queryDbStorageOfService);

// NOTE: only works with 1 ReadModel per Service !
let queryDbStorageOfAllContextsExn = (contexts, serviceName) =>
  queryDbStorageOfAllContexts(contexts, serviceName)
  ->ResourceQuery.unwrapResource("QueryDb", serviceName);