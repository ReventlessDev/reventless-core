import { registerDcbConfig } from "@reventlessdev/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res.mjs";
import { resolveModule } from "@reventlessdev/reventless-aws/src/util/Util_Bundle.res.mjs";

const pkg = "@reventlessdev/online-shop-hybrid-catalog/src";
registerDcbConfig("Catalog", undefined, [
  resolveModule(pkg + "/Product/StateChangeSlice/AddProduct.res.mjs"),
  resolveModule(pkg + "/Product/StateChangeSlice/ChangeProductName.res.mjs"),
  resolveModule(pkg + "/Product/StateChangeSlice/ChangeProductDescription.res.mjs"),
  resolveModule(pkg + "/Product/StateChangeSlice/ChangeProductPrice.res.mjs"),
  resolveModule(pkg + "/Product/StateChangeSlice/RecordProductDemand.res.mjs"),
], undefined);

export { default } from "./Main.res.mjs";
