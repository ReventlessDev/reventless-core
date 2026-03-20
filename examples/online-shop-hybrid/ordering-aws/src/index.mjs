import { registerDcbConfig } from "@reventlessdev/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res.mjs";
import { resolveModule } from "@reventlessdev/reventless-aws/src/util/Util_Bundle.res.mjs";

const pkg = "@reventlessdev/online-shop-hybrid-ordering/src";
registerDcbConfig("Ordering", undefined, [
  resolveModule(pkg + "/Order/StateChangeSlice/PlaceOrder.res.mjs"),
  resolveModule(pkg + "/Order/StateChangeSlice/ShipOrder.res.mjs"),
  resolveModule(pkg + "/Order/StateChangeSlice/CancelOrder.res.mjs"),
  resolveModule(pkg + "/CatalogProduct/StateChangeSlice/SyncCatalogProduct.res.mjs"),
], undefined);

export { default } from "./Main.res.mjs";
