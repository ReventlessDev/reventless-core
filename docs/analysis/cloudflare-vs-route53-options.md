# Cloudflare → AWS: DNS-Only Migration vs Registrar Transfer

Analysis comparing two paths for moving a Cloudflare-registered domain into AWS, focused on cost, effort, risk, and ongoing operational impact. Companion to [`docs/guides/cloudflare-to-route53.md`](../guides/cloudflare-to-route53.md), which documents Option A in detail.

## TL;DR

| Dimension | Option A — DNS only on Route 53 | Option B — Full transfer to Route 53 |
|---|---|---|
| Setup effort | ~1 hour | ~1 hour active + 5–7 days waiting |
| Cutover risk | Reversible in minutes | Effectively irreversible for ~60 days |
| Annual cost (per domain) | $6 + $6–10 reg @ Cloudflare = **~$12–16** | $13–$15 @ AWS = **~$13–15** |
| Reversibility | Re-point nameservers back to Cloudflare | Must initiate transfer-back (~$10, 5–7 days) |
| Ongoing admin surface | Two providers (auth at Cloudflare, DNS at AWS) | One provider (AWS) |
| Recommended default | **Yes** — pick this unless you have a reason | Only when consolidation matters more than agility |

**Recommendation:** Option A. The cost difference is negligible (~$1–3/year), and the operational reversibility is worth far more than the modest convenience of single-provider management.

## Cost comparison

### Option A — DNS-only

| Item | Cost | Notes |
|---|---|---|
| Cloudflare domain registration | $0–$10/year | Cloudflare Registrar is at-cost (no markup); price varies by TLD. `.com` is currently ~$10.44/year. |
| Route 53 hosted zone | $0.50/month × 12 = **$6/year** | Per zone, regardless of query volume. |
| Route 53 queries | $0.40 per million (first 1B) | Most apps: < $1/year. A 10M-query/month domain = $4/month = $48/year. |
| ACM certificates | $0 | Public certs are free; auto-renew if DNS validation records stay in place. |
| **Total (typical low-traffic domain)** | **~$12–16/year** | |

### Option B — Transfer to Route 53

| Item | Cost | Notes |
|---|---|---|
| Transfer fee (one-time) | ~$10–15 | Equals a 1-year renewal at AWS pricing — domain expiry pushed out by 1 year. |
| AWS domain registration (ongoing) | ~$13–15/year for `.com` | AWS marks up TLD prices vs Cloudflare's at-cost pricing. |
| Route 53 hosted zone | **$6/year** | Same as Option A. |
| Route 53 queries | Same as Option A | Same as Option A. |
| ACM certificates | $0 | Same as Option A. |
| **Total (typical low-traffic domain)** | **~$19–21/year** | |

### Cost delta

For a typical `.com`:

- **Option A:** ~$12–16/year (depending on Cloudflare TLD pricing).
- **Option B:** ~$19–21/year.

**Option B costs $4–8/year more per domain.** Cloudflare Registrar's at-cost pricing on TLDs is the source of the gap — AWS marks up registrations, while Cloudflare does not. For one or two domains the difference is negligible; for an org managing 50+ domains it adds up to a few hundred dollars/year.

Some TLDs (`.io`, `.dev`, `.app`) show a much larger gap — AWS often charges 30–50% more than Cloudflare for these. Verify on a per-TLD basis if you have anything other than `.com`/`.net`/`.org`.

## Effort comparison

### Option A — DNS-only

**Active work: ~1 hour**, mostly:

1. Export Cloudflare DNS records (5 min).
2. Create Route 53 hosted zone (2 min).
3. Recreate records in Route 53 (20–40 min, depends on record count).
4. Switch nameservers at Cloudflare (2 min).
5. Verify DNS propagation (5–60 min wait).
6. Post-cutover checklist (15 min).

**Waiting: minutes to ~48h** for nameserver propagation, but the domain remains functional throughout — old resolvers keep using Cloudflare records, new resolvers see Route 53 records, and both should answer with the same values if Step 3 was done correctly.

### Option B — Transfer registration

**Active work: ~1 hour**, similar to Option A plus transfer initiation:

1. Unlock domain at Cloudflare (2 min).
2. Disable Cloudflare's registry lock (2 min).
3. Request EPP/auth code from Cloudflare (a few minutes; some TLDs require a 60-day age, see below).
4. Initiate transfer at Route 53 → **Registered domains → Transfer in** (5 min).
5. Approve the WHOIS-admin confirmation email (1 min, but must happen within 5 days).
6. Wait for transfer completion (5–7 days).
7. After transfer: create hosted zone (Route 53 auto-creates one in most cases) and configure records (same as Option A Steps 1–6).

**Waiting: 5–7 days.** During this window the domain is in a transfer state; DNS still works via Cloudflare, but nameserver changes are blocked.

### ICANN constraints that affect Option B

- A domain transferred or newly registered within the last **60 days cannot be transferred** between registrars. This is an ICANN rule, not a Cloudflare or AWS limitation.
- After a transfer to AWS, the domain is similarly locked at AWS for 60 days — you cannot revert to Cloudflare immediately if you change your mind.
- The domain's expiry date is extended by 1 year as part of the transfer. If you transfer 11 months into a renewal cycle, you effectively pay for ~2 years of registration at the transfer moment.

## Reversibility and risk

### Option A

- **Rollback:** change nameservers at Cloudflare back to their defaults. Cloudflare retains the DNS records (assuming the zone wasn't deleted), so resolution resumes within minutes once propagation completes.
- **Risk profile:** low. The cutover is a single nameserver change; both sides hold the same records during the transition window.
- **Failure mode:** misconfigured records in Route 53 → fix in Route 53 (no need to roll back the nameserver change).

### Option B

- **Rollback during transfer:** can be cancelled at Cloudflare before the 5-day approval window expires.
- **Rollback after transfer:** requires a **transfer-out** from AWS back to Cloudflare. This takes another 5–7 days, costs another ~$10, and is **blocked for the first 60 days** post-transfer (ICANN rule).
- **Risk profile:** moderate. The DNS-record work is the same risk as Option A, plus a multi-day window where the domain is in transfer limbo and ownership records are mid-flight.
- **Failure mode:** stuck transfer (missed approval email, WHOIS email out of date, EPP code typo) → restart the 5–7 day clock.

## Ongoing operational impact

### Option A

- Two dashboards: Cloudflare for registration/WHOIS/auto-renew, AWS for DNS.
- Renewal billing comes from Cloudflare (which auto-renews at cost — no surprise charges).
- WHOIS privacy is free at Cloudflare (mandatory, not optional).
- Cloudflare's 2FA + account security applies to registration; AWS IAM applies to DNS records. Two account compromises needed to fully hijack the domain.

### Option B

- One dashboard for everything.
- Renewal billing comes through AWS (consolidated with the rest of your AWS bill).
- WHOIS privacy is free at Route 53 (enabled by default for supported TLDs).
- Single account compromise vector (AWS root or IAM with `route53domains:*` permissions). Mitigate with MFA + strong IAM policies + service control policies.

## When each option fits

### Pick Option A if…

- You have **fewer than ~20 domains** and the per-domain cost difference doesn't matter.
- You value **operational reversibility** (e.g. early-stage projects, exploratory work, anything where you might change your mind).
- Cloudflare is already a trusted account in the org (billing, 2FA, recovery email are all set up).
- You want to **isolate registration from DNS** as a defense-in-depth measure — compromising AWS does not let an attacker change registrar-level settings.
- You're a Reventless app developer pointing a single domain at one platform — the marginal admin overhead is tiny.

### Pick Option B if…

- You're managing **dozens of domains** and want a single source of truth.
- You need **AWS-native automation** for domain operations (transfers, renewals, WHOIS) via the `route53domains` API.
- Your finance/procurement team mandates **consolidated AWS billing**.
- You don't expect to ever move off AWS — and you've accepted the 60-day lock-in risk.
- You're standardizing infrastructure-as-code (Pulumi/Terraform) where having the domain resource adjacent to the rest of the AWS stack is a meaningful win.

## Hybrid considerations

There is no real hybrid — Option A is already the hybrid path (DNS at AWS, registration at Cloudflare). The alternatives are full ownership at one provider or the other.

A related decision, not covered here: whether to keep Cloudflare as DNS provider (proxied) and create records pointing at AWS resources. That preserves Cloudflare's CDN/WAF/proxy features but skips Route 53 entirely. It's a third path, not a variation of A or B, and trades AWS-native DNS automation for Cloudflare's edge features.

## Recommendation

**Default to Option A.**

The cost gap is small (~$4–8/year per `.com`, larger for some TLDs). The effort is roughly equivalent on the active side, but Option A finishes in an afternoon while Option B takes a week and locks you in for 60 days. The reversibility difference is the deciding factor: nameserver changes are minutes-to-revert, registrar transfers are days-to-revert with a hard ICANN waiting period.

Choose Option B only when the value of single-provider consolidation clearly exceeds the value of optionality — typically at significant domain volumes or in organizations with strict procurement consolidation requirements.

For Reventless app developers specifically, Option A is almost always correct: the work of pointing DNS at AppSync/CloudFront/API Gateway is identical either way, and keeping registration separate preserves the ability to migrate platforms (or providers) without a registrar transfer in the critical path.
