// An Orders view whose trail opts states into server-side queries, as the ppx
// writes it for `@trail({index: […]})`.

@schema
type lifecycle =
  | Placed
  | Shipped
  | Cancelled

@schema
type order = {
  orderId: string,
  customerId: string,
  lifecycle: lifecycle,
  trail: Reventless.Lifecycle.Trail.t<lifecycle>,
}

let annotated = (~trailIndex: array<string>, ~owner as _: bool) =>
  orderSchema
  ->S.Metadata.set(
    ~id=Reventless.StateAnnotations.stateAnnotationsId,
    {
      Reventless.StateAnnotations.ids: ["orderId"],
      compositeIds: [],
      subIds: [],
      compositeSubIds: [],
      indexes: [],
      hidden: [],
      summary: [],
      drillTargets: [],
      drillTargetKeys: [],
      collapsed: [],
      scan: [],
      scanSort: [],
      semantic: [],
      metric: [],
      lifecycle: Some("lifecycle"),
      groupBy: None,
      visibility: None,
      live: None,
      retired: None,
      trailIndex,
    },
  )
  ->S.castToUnknown
