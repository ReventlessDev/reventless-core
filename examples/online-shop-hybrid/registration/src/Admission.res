// How each of the shop's roles is admitted. Shoppers sign themselves up; every
// other role is made by hand, from the accounts file locally and by
// `provision-accounts` on AWS. This table is the hard cap: no policy an
// administrator records can open a role it does not declare self-service.
let table = Reventless.Admission.declare([
  (Roles.Shopper, SelfService),
  (Merchandiser, Provisioned),
  (Fulfilment, Provisioned),
  (Admin, Provisioned),
])

/** Whether visitors may sign themselves up for `role`. A role the table does
    not know is not. */
let isSelfService = (role: Reventless.Role.name) => table->Reventless.Admission.isSelfService(role)
