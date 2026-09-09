// AUTO-GENERATED — do not edit. Run `pnpm run check:lifecycle:update` to update.
//
// What catalog's own given/when/then scenarios say about each command: the
// states one shows it taking effect from, the states those land in, and whether
// it brings a row into existence. `Plugin_Structure` prefers this to the
// `@transition` annotation where it says anything, and falls back to the
// annotation where it is silent.

let model: array<Reventless.Plugin.derivedEdge> = [
  {
    component: "AddCategory",
    command: "AddCategory",
    level: Reventless.Plugin.Collection,
    allowedStates: [],
    targets: ["Listed"],
  },
  {
    component: "AddProduct",
    command: "AddProduct",
    level: Reventless.Plugin.Collection,
    allowedStates: [],
    targets: ["Listed"],
  },
  {
    component: "ArchiveCategory",
    command: "ArchiveCategory",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Listed"],
    targets: ["Archived"],
  },
  {
    component: "ArchiveProduct",
    command: "ArchiveProduct",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Listed"],
    targets: ["Archived"],
  },
  {
    component: "CategoryImages",
    command: "RemoveCategoryImage",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Listed"],
    targets: [],
  },
  {
    component: "CategoryImages",
    command: "SetCategoryImage",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Listed"],
    targets: [],
  },
  {
    component: "CategoryImages",
    command: "SetCategoryImageAltText",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Listed"],
    targets: [],
  },
  {
    component: "ChangeProductDescription",
    command: "ChangeProductDescription",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Archived", "Listed"],
    targets: [],
  },
  {
    component: "ChangeProductName",
    command: "ChangeProductName",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Archived", "Listed"],
    targets: [],
  },
  {
    component: "ChangeProductPrice",
    command: "ChangeProductPrice",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Archived", "Listed"],
    targets: [],
  },
  {
    component: "DiscontinueProduct",
    command: "DiscontinueProduct",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Archived", "Listed"],
    targets: ["Discontinued"],
  },
  {
    component: "ProductImages",
    command: "AttachProductImage",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Archived", "Listed"],
    targets: [],
  },
  {
    component: "ProductImages",
    command: "RemoveProductImage",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Archived", "Listed"],
    targets: [],
  },
  {
    component: "ProductImages",
    command: "SetPrimaryProductImage",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Archived", "Listed"],
    targets: [],
  },
  {
    component: "ProductImages",
    command: "SetProductImageAltText",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Archived", "Listed"],
    targets: [],
  },
  {
    component: "RenameCategory",
    command: "RenameCategory",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Listed"],
    targets: [],
  },
  {
    component: "UnarchiveProduct",
    command: "UnarchiveProduct",
    level: Reventless.Plugin.Instance,
    allowedStates: ["Archived"],
    targets: ["Listed"],
  },
]
