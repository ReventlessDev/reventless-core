// Companion fixtures module for [WithManualOpen_GWT.res]. The test file
// opens this module manually, so the PPX must NOT duplicate the open.

open WithManualOpen

let addCategoryBooks = AddCategory({categoryId: "c2", name: "Books"})
let booksCategoryAdded = CategoryAdded({categoryId: "c2", name: "Books"})
