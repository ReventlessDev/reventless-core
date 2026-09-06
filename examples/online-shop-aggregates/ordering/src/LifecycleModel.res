// AUTO-GENERATED — do not edit. Run `pnpm run check:lifecycle:update` to update.
//
// What ordering's own given/when/then scenarios say about each command: the
// states one shows it taking effect from, the states those land in, and whether
// it brings a row into existence. `Plugin_Structure` prefers this to the
// `@transition` annotation where it says anything, and falls back to the
// annotation where it is silent.

let model: array<Reventless.Plugin.derivedEdge> = [
  {component: "Order", command: "Cancel", level: Reventless.Plugin.Instance, allowedStates: ["Placed"], targets: ["Cancelled"]},
  {component: "Order", command: "Place", level: Reventless.Plugin.Collection, allowedStates: [], targets: ["Placed"]},
  {component: "Order", command: "Refund", level: Reventless.Plugin.Instance, allowedStates: ["Cancelled"], targets: ["Refunded"]},
  {component: "Order", command: "Ship", level: Reventless.Plugin.Instance, allowedStates: ["Placed"], targets: ["Shipped"]},
]
