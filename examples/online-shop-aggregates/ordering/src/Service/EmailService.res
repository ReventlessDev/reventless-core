// Stub email service for the example.
//
// The implementation goes through a `ref`-held `backend` so that tests can
// install a recording mock (see `EmailService_Mock.res` next to the GWT files
// — Option C of the `sideeffect-gwt` plan). Production code still calls
// `EmailService.sendOrderConfirmation(...)` directly; the indirection is
// invisible at the call site.

type backend = {
  sendOrderConfirmation: (~email: string, ~orderId: string) => promise<unit>,
}

let liveBackend: backend = {
  sendOrderConfirmation: async (~email as _, ~orderId as _) => {
    Console.log("[EmailService] Order confirmation sent")
  },
}

let current = ref(liveBackend)

let sendOrderConfirmation = (~email, ~orderId) =>
  current.contents.sendOrderConfirmation(~email, ~orderId)
