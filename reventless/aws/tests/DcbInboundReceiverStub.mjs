// `buildInboundReceiver` over the EpInboundTestSlice fixture, publishing into an
// array. Answers `[outcome, publishedCount]`.
import { buildInboundReceiver } from "@reventlessdev/reventless-aws/src/adapter/Runtime/DcbCommandTopicEntryPoint_Ops.res.mjs";
import * as spec from "./EpInboundTestSlice.res.mjs";
import * as translation from "./EpInboundTestSliceTranslation.res.mjs";

export async function receiveWithStubPublish(args, identity) {
  const published = [];
  const receive = buildInboundReceiver(spec, translation, async (cmds) => { published.push(...cmds); }, undefined);
  const outcome = await receive(args, identity);
  return [outcome, published.length];
}
