// AUTO-GENERATED — do not edit. Run `pnpm run check:lifecycle:update` to update.
//
// What ordering's own given/when/then scenarios say about each command: the
// states one shows it taking effect from, the states those land in, and whether
// it brings a row into existence. `Plugin_Structure` prefers this to the
// `@transition` annotation where it says anything, and falls back to the
// annotation where it is silent.

let model: array<Reventless.Plugin.derivedEdge> = [
  {
    component: "CancelOrder",
    command: "CancelOrder",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Placed"],
    targets: ["Cancelled"],
  },
  {
    component: "CancelOrder",
    command: "ReopenOrder",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Cancelled"],
    targets: ["Placed"],
  },
  {
    component: "Customer",
    command: "Deactivate",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Active"],
    targets: ["Deactivated"],
  },
  {
    component: "Customer",
    command: "Reactivate",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Deactivated"],
    targets: ["Active"],
  },
  {
    component: "Customer",
    command: "Register",
    level: Reventless.Plugin.Collection,
    allowedStates: [],
    targets: ["Active"],
  },
  {
    component: "Customer",
    command: "SetAddressLocation",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Active"],
    targets: [],
  },
  {
    component: "Customer",
    command: "UpdateAddress",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Active"],
    targets: [],
  },
  {
    component: "Customer",
    command: "UpdateEmail",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Active"],
    targets: [],
  },
  {
    component: "PlaceOrder",
    command: "PlaceOrder",
    level: Reventless.Plugin.Collection,
    allowedStates: [],
    targets: ["Placed"],
  },
  {
    component: "ShipOrder",
    command: "ShipOrder",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Placed"],
    targets: ["Shipped"],
  },
]
