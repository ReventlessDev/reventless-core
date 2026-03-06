// Stub email service for the example.
// In production this would call an external email API.

let sendOrderConfirmation = async (~email as _: string, ~orderId as _: string) => {
  Console.log("[EmailService] Order confirmation sent")
}
