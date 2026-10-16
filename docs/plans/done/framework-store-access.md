# Plan: who may read the framework's own stores

**Status.** Planned 2026-10-16, from a finding of the deployed check in
[the automations-on-a-time plan](automations-that-run-on-a-time.md#the-deployed-check-2026-10-16).
Done 2026-10-16: every phase's exit is met. [Q1](#open-questions) is left open.

**In plain words.** Some components keep a store of their own beside the ones an application
declares: an automation keeps its to-do list and its schedules, an outbound translation its
to-do list, an inbound translation an audit of what it received. The framework creates these
stores and gives each a list query, so an operator can see what the component is doing. Today
every one of them may be read by **any signed-in caller**. A shopper can therefore read which
customers are about to be notified about which orders, and at what time of day each customer
gets their marketing digest. Nobody chose that: the builders copied `AllowAuthenticated`, the
default for a store an application declares. This plan lets only the deployment's operators
read them.

**Why now.** The marketing digest put per-customer times in such a store, and the deployed
check read one customer's time while signed in as another. The to-do stores have exposed
recipients and order ids the same way since they gained a list query.

**Goal.** A framework-made store answers its queries to the deployment's operators only, on
every platform, and the GraphQL contract says so.

**Non-goals.** A component choosing a rule of its own for its stores (an
`@@reventless.authorize` on an automation's spec); that is an addition for when someone needs
it. Owner-scoping a to-do row to the recipient it names: a row's id is the component's own key,
not a principal.

**Phases** are numbered O0 to O2 (O for *operators*).

---

## Which stores

| Store | Made by | List query today | After |
|---|---|---|---|
| `<Slice>Todo` | [AutomationSlice_Builder.res](../../../reventless/core/src/components/AutomationSlice/AutomationSlice_Builder.res) | any signed-in caller | operators |
| `<Slice>Schedule` | the same | any signed-in caller | operators |
| `<Slice>Todo` | [OutboundTranslationSlice_Builder.res](../../../reventless/core/src/components/OutboundTranslationSlice/OutboundTranslationSlice_Builder.res) | any signed-in caller | operators |
| `<Slice>Audit` | [InboundTranslationSlice_Builder.res](../../../reventless/core/src/components/InboundTranslationSlice/InboundTranslationSlice_Builder.res) | any signed-in caller | operators |
| `<Counter>References`, `<Counter>Counts` | [Counter_Builder.res](../../../reventless/core/src/components/Counter/Counter_Builder.res) | none (`NoResolvers`) | unchanged |

**Operators** are the deployment's elevated groups: the same list that lifts `@owner` and
`@retired` for a caller, set by `REVENTLESS_ELEVATED_GROUPS` or by the platform root
([OwnerScope.res](../../../reventless/spec/src/types/OwnerScope.res)). One list, so two parts of
the system cannot disagree about who an operator is.

## O0: check what the plan assumes

No code. Each result is written into this section with its date.

1. **The elevated list is known where the builders run.** The rule is read when a store's
   resolvers are made: at deploy on AWS, at start locally. On AWS the list may be set in the
   Lambda's environment and not in the deploy runner's; then the deploy cannot gate on it.
2. **An empty list denies, rather than allows.** `AllowRoles([])` renders as the `__deny_all__`
   sentinel group on AppSync ([AppSync_SdlDecorate.res](../../../reventless/aws/src/components/Api/AppSync_SdlDecorate.res));
   the local resolvers must refuse it too.
3. **The elevated list is groups, and a rule names roles.** `Role.groupOf` maps a role to its
   group; the reverse has to be exact, or a deployment whose operator group is not named after a
   role is gated on nothing.
4. **What reads these stores today**, in this repository and the published packages that
   depend on core: a consumer reading them as a non-operator breaks.

**Exit:** all four answered; a failed premise changes [O1](#o1-operators-only) before it starts.

### Results (2026-10-16)

1. **Holds.** The AWS deploy program has a list of its own: `REVENTLESS_ELEVATED_GROUPS` (both
   deploy jobs of `deploy-reventless-aws.yml` set it), else the `Admin` default that
   `ReventlessAws.Platform.Make` states before any plugin is built. The same program writes that
   list into every Lambda (`Util_OwnerScopeEnv.applyElevatedGroupsDefault`), so the directive and
   the runtimes read one value. They differ only where a deployment pins the variable in one
   Lambda's own environment. Locally the list is whatever the root states before the plugins are
   built. The **local platform states no default**, so the DCB and aggregates examples, which state
   none, will have no operator. That is the empty case of the next answer.
2. **Holds.** `AllowRoles([])` becomes the `__deny_all__` group on AppSync, and locally
   `Authorization.isAllowed` answers `false` for it.
3. **Holds, with one case to refuse.** `elevatedGroups()` already turns roles into groups. Going
   back, a group `g` is named by the role mapped to it (`roleGroups`), else by the role `g`
   itself, which maps to `g` unless it was renamed. Only that last case has no exact role: an
   operator group `Admin` while the role `Admin` stands for another group. It is refused at
   deploy and start, not dropped. So no new rule is needed: operators are
   `AllowRoles` of the roles that stand for the elevated groups.
4. **Only the hybrid seed** reads these stores over GraphQL (its view sweep in
   `HybridSeedData.res`), and it signs in as `admin`, which is elevated. The UI and tools
   repositories never name one. The GWT `thenTodos` / `thenSchedules` read the store directly,
   not through a query.

**Two findings change [O1](#o1-operators-only):**

- **AWS gates only two of a store's fields.** The query permission is stamped on the single
  and list fields. `…ByIds`, `…Refs`, `…Items` and `…By<Index>` get the open Cognito directive,
  and the AppSync resolvers ignore `authorization`. So on AWS **any** `AllowRoles` view, an
  application's included, can be read by any signed-in caller through those doors. The local
  resolvers check every door. Gating the framework's stores without closing this leaves them
  readable, so [O1](#o1-operators-only) closes it.
- **The domain API golden does not change.** It is an introspection of the local server, and
  introspection carries no directives. The gate is pinned by the `AppSync_Adapter` test.

## O1: operators only

- **One permission for operators**, `OwnerScope.operators()` beside the elevated list:
  `AllowRoles` of the roles that stand for the elevated groups, refusing a group no role can
  name ([O0](#o0-check-what-the-plan-assumes)'s third answer).
- **The four stores use it**, in place of `AllowAuthenticated`: in their store specs (what the
  local resolvers check) and in their query entries (what AWS stamps).
- **Every door of a query entry is gated on AWS**: the permission reaches `…ByIds`, `…Refs`,
  `…Items` and `…By<Index>`, named by the same function the SDL generator uses.

**Tests:** operators resolved from groups, from renamed roles, empty, and the refused case
(`OwnerScopeTest`); the AWS directive on every door the SDL generator emits for a roles-gated
entry (`AppSync_AdapterTest`). The domain API golden is unchanged.

**Checked locally, 2026-10-16**, on the hybrid shop (in memory, isolated ports): after a customer
registration and a product import, `shopper` and `merch` read no rows from
`Ordering_AnnounceRecipientContactTodos` or `Catalog_ImportProductAudits`, nor through the by-id,
by-ids and `…Refs` doors; `fulfil` and `admin` read them. Locally a refusal is an empty answer,
not an error, which is why the check needed rows to be meaningful.

**Exit:** on the deployed alpha stack, `shopper` is refused `Ordering_MarketingDigestSchedules`
and `Ordering_NotificationIntakeTodos`, and `admin` reads both.

**Met 2026-10-16**, on the hybrid shop's alpha merged API with the `shopper` and `admin` accounts.
Before the deploy, `shopper` read rows from both stores and from `Catalog_ImportProductAudits`,
and was answered by `Ordering_CustomersByIds`, a door of a view open to `Admin` and `Fulfilment`
only. After it, `shopper` is refused (`Unauthorized`) on each store's list, by-ids and `…Refs`
fields, on the audits, and on `Ordering_CustomersByIds`; `admin` is served all of them.

## O2: the guide and the release

- **The authorization guide** ([authorization.md](../../../packages/doc/docs-app/authorization.md))
  gains *The framework's own stores*: which they are, who may read them, and why.
- **The changelog** names the breaking change: a non-operator client reading one of these
  stores is refused, and on AWS a roles-gated view's `…ByIds`, `…Refs`, `…Items` and
  `…By<Index>` doors now refuse callers outside its roles. Both go in the commit's
  `BREAKING CHANGE` footer.

**Exit:** published with the next core alpha.

**Met 2026-10-16:** `reventless-core` 3.0.0-alpha.297, `reventless-spec` 3.0.0-alpha.166 and
`reventless-aws` 3.0.0-alpha.384 are on npm, and each changelog lists the change under
*BREAKING CHANGES*.

## Open questions

**Q1. Should the automatic UI keep its panels for these stores?** They are bookkeeping, and
after [O1](#o1-operators-only) an ordinary user's panel would only show a refusal.
**Recommendation: hide them from non-operators**, through the store's visibility, so the
automatic UI still offers them to an operator.
