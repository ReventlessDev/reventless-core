// Companion fixtures module for [WithFixtures_GWT.res]. The PPX detects this
// sibling by filename and auto-injects [open WithFixtures_Fixtures] into the
// GWT test body, so the test can reference [addCategoryElectronics] /
// [electronicsCategoryAdded] unqualified.

open WithFixtures

let addCategoryElectronics = AddCategory({categoryId: "c1", name: "Electronics"})
let electronicsCategoryAdded = CategoryAdded({categoryId: "c1", name: "Electronics"})
