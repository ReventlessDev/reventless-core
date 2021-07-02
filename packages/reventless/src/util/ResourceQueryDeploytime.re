open ReventlessSpec.Adapter;

let find: (array('a), string) => option('a) =
  (resources, name) =>
    resources->Belt.Array.reduce(None, (result, resource) =>
      resource##name == name ? Some(resource) : result
    );

let eventTopicPublisherOfAllServices:
  (array(Service.outputs), string) => option(resource) =
  (services, serviceName) =>
    services
    ->find(serviceName)
    ->Belt.Option.map(service => service##aggregate##eventTopic##publisher);

let eventTopicPublisherOfAllServicesExn = (services, serviceName) =>
  eventTopicPublisherOfAllServices(services, serviceName)
  ->ResourceQuery.unwrapResource("EventTopic", serviceName);

let readModelOfService: Service.outputs => ReadModel.outputs =
  service => service##readModel;

let queryDbOfReadModel: ReadModel.outputs => QueryDb.outputs =
  readModel => readModel##queryDb;

let queryDbOfService: Service.outputs => QueryDb.outputs =
  service => service->readModelOfService->queryDbOfReadModel;

let allResolversMakers:
  array(Service.outputs) => array(QueryDb.resolversResourcesMaker) =
  services =>
    services
    ->Belt.Array.map(queryDbOfService)
    ->Belt.Array.map(queryDb => queryDb##resolversMaker);

let queryDbStorageOfService: Service.outputs => resource =
  service => service->queryDbOfService##storage;

// NOTE: only works with 1 ReadModel per Service !
let queryDbStorageOfAllServicesExn = (services, serviceName) =>
  services
  ->find(serviceName)
  ->Belt.Option.map(queryDbStorageOfService)
  ->ResourceQuery.unwrapResource("QueryDb", serviceName);

let allEventLogStorages:
  (array(Service.outputs), string => bool) => array(resource) =
  (services, keep) =>
    services->Belt.Array.keepMap(service =>
      keep(service##name)
        ? Some(service##aggregate##eventLog##storage) : None
    );

let allQueryDbStorages:
  (array(Service.outputs), string => bool) => array(resource) =
  (services, keep) =>
    services->Belt.Array.keepMap(service =>
      keep(service##name) ? Some(service##readModel##queryDb##storage) : None
    );
