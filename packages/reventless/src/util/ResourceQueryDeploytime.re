let find: (array('a), string) => option('a) =
  (resources, name) =>
    resources->Belt.Array.reduce(None, (result, resource) =>
      resource##name == name ? Some(resource) : result
    );

let eventTopicPublisherOfAllServices:
  (array(Service.t), string) => option(Adapter.resource) =
  (services, serviceName) =>
    services
    ->find(serviceName)
    ->Belt.Option.map(service => service##aggregate##eventTopic##publisher);

let eventTopicPublisherOfAllServicesExn = (services, serviceName) =>
  eventTopicPublisherOfAllServices(services, serviceName)
  ->ResourceQuery.unwrapResource("EventTopic", serviceName);

let readModelOfService: Service.t => ReadModel.outputs =
  service => service##readModel;

let queryDbOfReadModel: ReadModel.outputs => QueryDb.outputs =
  readModel => readModel##queryDb;

let queryDbOfService: Service.t => QueryDb.outputs =
  service => service->readModelOfService->queryDbOfReadModel;

let allResolversMakers:
  array(Service.t) => array(QueryDb.resolversResourcesMaker) =
  services =>
    services
    ->Belt.Array.map(queryDbOfService)
    ->Belt.Array.map(queryDb => queryDb##resolversMaker);

let queryDbStorageOfService: Service.t => Adapter.resource =
  service => service->queryDbOfService##storage;

// NOTE: only works with 1 ReadModel per Service !
let queryDbStorageOfAllServicesExn = (services, serviceName) =>
  services
  ->find(serviceName)
  ->Belt.Option.map(queryDbStorageOfService)
  ->ResourceQuery.unwrapResource("QueryDb", serviceName);

let allEventLogStorages: array(Service.t) => array(Adapter.resource) =
  services =>
    services->Belt.Array.map(service => service##aggregate##eventLog##storage);

let allQueryDbStorages: array(Service.t) => array(Adapter.resource) =
  services =>
    services->Belt.Array.map(service => service##readModel##queryDb##storage);
