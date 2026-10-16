# Plan: who may read the framework's own stores

**Status.** Planned 2026-10-16, from a finding of the deployed check in
[the automations-on-a-time plan](automations-that-run-on-a-time.md#the-deployed-check-2026-10-16).
Not started.

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
| `<Slice>Todo` | [AutomationSlice_Builder.res](../../reventless/core/src/components/AutomationSlice/AutomationSlice_Builder.res) | any signed-in caller | operators |
| `<Slice>Schedule` | the same | any signed-in caller | operators |
| `<Slice>Todo` | [OutboundTranslationSlice_Builder.res](../../reventless/core/src/components/OutboundTranslationSlice/OutboundTranslationSlice_Builder.res) | any signed-in caller | operators |
| `<Slice>Audit` | [InboundTranslationSlice_Builder.res](../../reventless/core/src/components/InboundTranslationSlice/InboundTranslationSlice_Builder.res) | any signed-in caller | operators |
| `<Counter>References`, `<Counter>Counts` | [Counter_Builder.res](../../reventless/core/src/components/Counter/Counter_Builder.res) | none (`NoResolvers`) | unchanged |

**Operators** are the deployment's elevated groups: the same list that lifts `@owner` and
`@retired` for a caller, set by `REVENTLESS_ELEVATED_GROUPS` or by the platform root
([OwnerScope.res](../../reventless/spec/src/types/OwnerScope.res)). One list, so two parts of
the system cannot disagree about who an operator is.

## O0: check what the plan assumes

No code. Each result is written into this section with its date.

1. **The elevated list is known where the builders run.** The rule is read when a store's
   resolvers are made: at deploy on AWS, at start locally. On AWS the list may be set in the
   Lambda's environment and not in the deploy runner's; then the deploy cannot gate on it.
2. **An empty list denies, rather than allows.** `AllowRoles([])` renders as the `__deny_all__`
   sentinel group on AppSync ([AppSync_SdlDecorate.res](../../reventless/aws/src/components/Api/AppSync_SdlDecorate.res));
   the local resolvers must refuse it too.
3. **The elevated list is groups, and a rule names roles.** `Role.groupOf` maps a role to its
   group; the reverse has to be exact, or a deployment whose operator group is not named after a
   role is gated on nothing.
4. **What reads these stores today**, in this repository and the published packages that
   depend on core: a consumer reading them as a non-operator breaks.

**Exit:** all four answered; a failed premise changes [O1](#o1-operators-only) before it starts.

## O1: operators only

- **One permission for operators**, in [Authorization.res](../../reventless/spec/src/types/Authorization.res)
  or beside the elevated list: the deployment's elevated groups as a `permission`. Whether
  that is a new rule (`AllowOperators`) or `AllowRoles` of the elevated roles is [O0](#o0-check-what-the-plan-assumes)'s third
  answer.
- **The four stores use it**, in place of `AllowAuthenticated`.
- **The goldens** of the hybrid shop's domain API change in the same commit: each of those
  stores' fields is gated on the operator groups.

**Tests:** a shopper is refused each store's list query and an operator served, locally and in
the AWS directive; an empty elevated list refuses everyone; the domain API golden.

**Exit:** on the deployed alpha stack, `shopper` is refused `Ordering_MarketingDigestSchedules`
and `Ordering_NotificationIntakeTodos`, and `admin` reads both.

## O2: the guide and the release

- **The authorization guide** ([authorization.md](../../packages/doc/docs-app/authorization.md))
  gains *The framework's own stores*: which they are, who may read them, and why.
- **The changelog** names the breaking change: a non-operator client reading one of these
  stores is refused.

**Exit:** published with the next core alpha.

## Open questions

**Q1. Should the automatic UI keep its panels for these stores?** They are bookkeeping, and
after [O1](#o1-operators-only) an ordinary user's panel would only show a refusal.
**Recommendation: hide them from non-operators**, through the store's visibility, so the
automatic UI still offers them to an operator.
