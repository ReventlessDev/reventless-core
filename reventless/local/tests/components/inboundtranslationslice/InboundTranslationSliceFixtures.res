// Test fixtures for InboundTranslationSlice callback tests.

// ─────────────────────────────────────────────────────────────
// Minimal DcbEventLog spec
// ─────────────────────────────────────────────────────────────

module OrderEventLog = {
  let moduleUrl: string = %raw(`import.meta.url`)
  @schema
  type event =
    PaymentConfirmed({orderId: @s.matches(Reventless.DcbTag.string) string, paymentId: string})
}

// ─────────────────────────────────────────────────────────────
// InboundTranslationSlice spec — payment webhook
// ─────────────────────────────────────────────────────────────

module PaymentWebhookSpec = {
  let name = "PaymentWebhook"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type externalInput = {paymentId: string, orderId: string, status: string}

  @schema
  type command =
    ConfirmPayment({orderId: @s.matches(Reventless.DcbTag.string) string, paymentId: string})

  let targetName = "ConfirmPayment"
  let externalSystem = None

  let translate = (input: externalInput) =>
    switch input.status {
    | "completed" =>
      Ok([(input.orderId, ConfirmPayment({orderId: input.orderId, paymentId: input.paymentId}))])
    | status => Error("Unknown payment status: " ++ status)
    }
}

// Two constructors under different roles; `kind` picks which the input becomes.
module CatalogFeedSpec = {
  let name = "CatalogFeed"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type externalInput = {kind: string, id: string}

  @schema
  type command =
    | AddProduct({productId: @s.matches(Reventless.DcbTag.string) string})
    | AddCategory({categoryId: @s.matches(Reventless.DcbTag.string) string})

  let targetName = "AddProduct"
  let externalSystem = None

  type role = Reventless.Role.name
  let merchandiser = Reventless.Role.make("Merchandiser")
  let admin = Reventless.Role.make("Admin")
  let authorizationOf = (name: string): Reventless.Authorization.rule<role> =>
    switch name {
    | "AddProduct" => AllowRoles([merchandiser])
    | "AddCategory" => AllowRoles([admin])
    | _ => DenyAll
    }

  let translate = (input: externalInput) =>
    switch input.kind {
    | "product" => Ok([(input.id, AddProduct({productId: input.id}))])
    | "both" =>
      Ok([
        (input.id, AddProduct({productId: input.id})),
        (input.id, AddCategory({categoryId: input.id})),
      ])
    | kind => Error("Unknown kind: " ++ kind)
    }
}

// A command whose schema writes an absent note as `null`, which the runtime value does not.
module NoteFeedSpec = {
  let name = "NoteFeed"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type externalInput = {orderId: string}

  @schema
  type command =
    Annotate({orderId: @s.matches(Reventless.DcbTag.string) string, note: @s.null option<string>})

  let targetName = "Annotate"
  let externalSystem = None

  let translate = (input: externalInput) => Ok([
    (input.orderId, Annotate({orderId: input.orderId, note: None})),
  ])
}
