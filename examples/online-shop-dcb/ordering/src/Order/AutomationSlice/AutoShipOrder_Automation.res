@@reventless.automation

// Bridge: re-export the per-source mappings from the sibling `_Mappings.res`.
// The merged `_Automation.res` shape (process + mappings inline) is the new
// convention; this two-line bridge keeps the legacy 3-file split working
// against the 2-arg `Platform.AutomationSlice.Make` signature until Phase 3.5
// folds `_Mappings.res` into this file.
module type Mapping = AutoShipOrder_Mappings.Mapping
let mappings = AutoShipOrder_Mappings.mappings

let process = (id, _item) => Some((id, ShipOrder({orderId: id})))
