// Order notification task — hosts side effects for the Order aggregate.
// Sends email confirmations when orders are placed.

open Reventless

let name = "OrderNotifications"

let setup = (_queryEngine, _queryBucketName, _opts) => {
  Task.sideEffects: [module(Order_EmailNotification): module(SideEffect.T)],
}
