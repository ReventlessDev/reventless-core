let findByService = (resources, service) =>
  resources->Belt.Array.getBy(resource => resource##service);
