// Stub email service for the example.
// In production this would call an external email API.

let sendOrderConfirmation = async (~email as _, ~orderId as _) => {
  Console.log("[EmailService] Order confirmation sent")
}
