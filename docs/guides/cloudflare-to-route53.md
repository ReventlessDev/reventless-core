# Migrating DNS from Cloudflare to AWS Route 53

This guide covers moving DNS for a domain registered at Cloudflare onto AWS Route 53 while keeping the registration at Cloudflare. The first part is generic and applies to any domain. The final section covers extra steps for Reventless app developers pointing the domain at a Reventless AWS deployment.

## When to use this guide

Use this approach when you want:

- DNS managed in AWS (alongside the rest of your infrastructure).
- To keep paying Cloudflare for registration only.
- Records to point directly at AWS resources (AppSync, CloudFront, API Gateway, ALB, S3) without an extra proxy hop.

Do **not** use this if you want to keep Cloudflare's CDN, WAF, or DDoS protection — those features require Cloudflare to remain authoritative for DNS. In that case, leave nameservers at Cloudflare and create records there that target AWS resources.

If you'd rather transfer the registration too, follow AWS's "Transfer a domain to Route 53" docs instead — this guide does not cover that path.

## Prerequisites

- AWS account with IAM permissions for Route 53: `route53:CreateHostedZone`, `route53:ChangeResourceRecordSets`, `route53:GetHostedZone`.
- Admin access to the Cloudflare dashboard for the domain.
- A complete list of current DNS records in Cloudflare (Step 1 captures this).
- A maintenance window for the cutover. Propagation usually completes in under an hour, but worst-case is up to 48 hours.

## Cost

- $0.50/month per hosted zone (billed for the full first month even if you delete the zone within 12 hours).
- $0.40 per million queries on the first billion queries/month.
- ACM public certificates are free.

## 1. Export existing DNS records from Cloudflare

Capture every live record before changing anything.

1. Cloudflare dashboard → select your domain → **DNS → Records**.
2. Click **Export** at the bottom — downloads a BIND-format zone file.
3. Review the file. Pay particular attention to:
   - **MX records** for email.
   - **TXT records** for SPF, DKIM, DMARC, and any third-party domain-verification tokens (Google Workspace, Microsoft 365, GitHub, Stripe, etc.).
   - **Proxied records** (orange cloud) — these currently resolve to Cloudflare IPs. In Route 53 they must point at your real origin (IP, AWS resource, or external hostname).
   - **Subdomain NS records** delegating to other DNS providers.

Lower the TTL on every record to 300 seconds **at least 24 hours before** the cutover. This makes the eventual switch (and any rollback) propagate fast.

## 2. Create the Route 53 hosted zone

**Console:**

1. Route 53 → **Hosted zones → Create hosted zone**.
2. Domain name: the apex, e.g. `example.com` (no `www.`).
3. Type: **Public hosted zone**.
4. Click **Create**.

**CLI:**

```bash
aws route53 create-hosted-zone \
  --name example.com \
  --caller-reference "$(date +%s)"
```

AWS auto-populates the zone with:

- An **NS** record at the apex listing 4 nameservers (e.g. `ns-123.awsdns-12.com`, `ns-456.awsdns-34.net`, `ns-789.awsdns-56.org`, `ns-012.awsdns-78.co.uk`).
- An **SOA** record.

Note the 4 nameserver values — you'll paste them into Cloudflare in Step 4.

## 3. Recreate DNS records in Route 53

Do this **before** switching nameservers — otherwise records disappear during propagation.

For each record from the Cloudflare export:

1. Route 53 → your hosted zone → **Create record**.
2. Set name, type, TTL, and value.
3. For records that previously pointed at Cloudflare's proxy, set the value to your real origin (EC2 IP, ALB DNS name, S3 website endpoint, CloudFront distribution, etc.).

### Use Alias records for AWS targets

Route 53 **Alias records** beat plain A/CNAME records when the target is an AWS resource:

- Free queries (no charge on alias lookups).
- Work at the zone apex (`example.com`, where standard CNAMEs are not allowed).
- Automatic IP updates when AWS rotates infrastructure.

### Bulk import via CLI

Convert the BIND export to a Route 53 change-batch JSON, then:

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id ZXXXXXXXXXXXX \
  --change-batch file://records.json
```

### Common gotchas

- **Apex CNAME is not allowed** in standard DNS — use a Route 53 Alias A record instead.
- **MX and TXT records**: copy verbatim, including quotes and trailing dots.
- **Wildcard records** (`*.example.com`): recreate them; some apps depend on them.

## 4. Switch nameservers at Cloudflare

This is the cutover. Once changed, the internet starts resolving via Route 53.

### Cloudflare Registrar constraint

If the domain is registered with **Cloudflare Registrar**, nameservers can only be changed when Cloudflare is **not** providing DNS proxying for the zone. You'll need to either:

- Disable the orange-cloud proxy on all records in Cloudflare DNS (set them all to "DNS only / gray cloud"), or
- Delete the zone from Cloudflare's DNS dashboard (registration is unaffected).

### Change the nameservers

1. Cloudflare dashboard → your domain → **Domain Registration → Nameservers** (or **DNS → Nameservers** depending on UI version).
2. Click **Use custom nameservers**.
3. Paste the 4 Route 53 NS values from Step 2.
4. Save. Cloudflare may require email confirmation.

## 5. Verify propagation

Check from multiple resolvers:

```bash
dig +short NS example.com @8.8.8.8
dig +short NS example.com @1.1.1.1
dig +short A example.com @8.8.8.8
dig +short MX example.com @8.8.8.8
```

You should see the 4 `awsdns` nameservers and your records resolving to the values from Step 3. For a global view, [whatsmydns.net](https://whatsmydns.net) works well.

## 6. Post-cutover checklist

- [ ] Apex and `www` load (test in incognito to bypass cached DNS).
- [ ] HTTPS is valid — the TLS cert lives on your origin or AWS service, not Cloudflare.
- [ ] Email delivery works (send a test to/from the domain; check the spam folder).
- [ ] Email auth records present: `dig TXT _dmarc.example.com`, `dig TXT example.com` (SPF), DKIM selector records.
- [ ] Third-party domain verifications still valid (Google Workspace, Microsoft 365, GitHub Pages, etc.).
- [ ] Subdomains (api, mail, blog) resolve correctly.
- [ ] Monitoring / uptime alerts not firing.

## 7. Rollback plan

If something breaks badly:

1. In Cloudflare, switch nameservers back to Cloudflare's defaults (Cloudflare shows the original pair on the Nameservers page).
2. Re-enable the orange-cloud proxy on records as needed.
3. Cloudflare DNS records are retained when you move off — they resume serving once nameservers point back. If you deleted the zone in Cloudflare, re-add it before rolling back.

The low TTLs from Step 1 make rollback propagate within minutes.

## 8. What you give up by moving off Cloudflare DNS

- CDN / global edge caching.
- WAF and DDoS protection.
- Cloudflare's free SSL certificate (your origin needs its own cert — use ACM if fronting via CloudFront/ALB/AppSync).
- Page Rules, Workers, Access policies.
- Cloudflare analytics.

---

## For Reventless app developers

The DNS mechanics above work as-is when pointing a domain at a Reventless deployment, but a Reventless platform on AWS needs a few extra pieces wired up. Read Sections 1–8 first; this section adds onto them.

### Map Reventless components to AWS DNS targets

| Reventless component | AWS resource you point DNS at | Record type |
|---|---|---|
| GraphQL API (AppSync) | AppSync custom domain → CloudFront edge | Alias A to AppSync custom domain |
| HTTP API gateway | API Gateway custom domain (regional or edge) | Alias A to API Gateway |
| Static frontend / Auto UI | CloudFront distribution fronting S3 | Alias A to CloudFront |
| Lambda Function URL behind CloudFront | CloudFront distribution | Alias A to CloudFront |

DynamoDB, SQS, and SNS (Reventless's storage and messaging adapters) don't need DNS changes — they're accessed via the AWS SDK, not your custom domain. Local in-memory dev (`reventless-in-memory`) is unaffected.

### Request an ACM certificate before the cutover

Each AWS service fronting your domain needs a TLS cert from AWS Certificate Manager. Request and validate it **while Cloudflare is still authoritative** so there's no HTTPS gap at the cutover.

**Region matters:**

- CloudFront, AppSync custom domain, and API Gateway **edge-optimized** endpoints — cert must live in **us-east-1**, regardless of where the rest of your stack runs.
- API Gateway **regional** endpoints and ALB — cert in the same region as the resource.

Steps:

1. ACM (in the right region) → **Request certificate** → public certificate → domain names (e.g. `example.com`, `*.example.com`).
2. Choose **DNS validation**. ACM gives you CNAME validation records.
3. Add the validation CNAMEs in Cloudflare DNS (gray cloud, not proxied).
4. Wait for ACM to show **Issued** (usually under 10 minutes).
5. After the Route 53 cutover, re-create the same validation CNAMEs in Route 53 so future renewals don't break.

### Wire the custom domain into your Pulumi stack

Reventless's AWS adapter creates the AppSync API, CloudFront distribution, and API Gateway. You attach the custom domain to those resources in your platform's Pulumi program.

Sketch (TypeScript Pulumi, conceptual):

```ts
const domain = new aws.appsync.DomainName("api-domain", {
  domainName: "api.example.com",
  certificateArn: cert.arn, // ACM cert in us-east-1
});

new aws.appsync.DomainNameApiAssociation("api-assoc", {
  apiId: reventlessApi.id,
  domainName: domain.domainName,
});

new aws.route53.Record("api-dns", {
  zoneId: hostedZone.zoneId,
  name: "api.example.com",
  type: "A",
  aliases: [{
    name: domain.appsyncDomainName,
    zoneId: domain.hostedZoneId,
    evaluateTargetHealth: false,
  }],
});
```

If the Route 53 hosted zone was created via the console (Step 2), you can either `pulumi import` it into your stack, or create the zone with Pulumi from the start and copy its NS values into Cloudflare. Importing creates a hosted zone in Pulumi state but does not migrate records — Step 1's BIND export is still the source for record recreation.

### Update CORS and frontend configuration

After moving to a custom domain:

- API: update Reventless API CORS allow-lists to include `https://app.example.com` (or whatever your frontend origin is).
- Frontend: point GraphQL / HTTP client at `https://api.example.com` instead of the raw AppSync / API Gateway URL. Update env vars and rebuild.

### Update auth callback URLs

If the Reventless platform uses Cognito (or any OAuth provider):

- Cognito app client **callback URLs** and **logout URLs** → new custom domain.
- IdP redirect URI allow-lists (Google, GitHub, etc.) → new custom domain.

### Auto UI / static asset hosting

If Auto UI is served from CloudFront + S3:

- Add the custom domain to the CloudFront distribution's **Alternate Domain Names (CNAMEs)** field.
- Reference the ACM cert (us-east-1) on the distribution.
- Invalidate the CloudFront cache after cutover if asset URLs reference the domain.

### Recommended cutover order for a Reventless app

1. Lower Cloudflare TTLs to 300s (≥ 24h before cutover).
2. Request ACM cert; validate via Cloudflare DNS; wait for **Issued**.
3. Update Pulumi stack to attach the custom domain to AppSync / API Gateway / CloudFront. `pulumi up`.
4. Create the Route 53 hosted zone (Section 2).
5. Add alias records pointing to AWS resources, plus all non-AWS records (MX, TXT, etc.).
6. Switch nameservers at Cloudflare (Section 4).
7. Verify DNS, HTTPS, GraphQL / HTTP API, and auth flows end-to-end.
8. Re-create the ACM validation CNAMEs in Route 53 so future renewals work.

### Reventless-specific gotchas

- **AppSync custom domain is edge-optimized only** — its cert must live in **us-east-1**, even if the AppSync API itself runs in another region.
- **API Gateway edge endpoints** also need the cert in us-east-1; regional endpoints want the cert in the API's own region.
- **Internal AWS services** (DynamoDB, SQS, SNS, S3 for task buckets) are reached via SDK — no DNS changes needed.
- **In-memory dev** is unaffected — no DNS, no ACM, no Pulumi changes when running locally with `reventless-in-memory`.
