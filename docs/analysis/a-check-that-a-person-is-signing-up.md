# A check that a person is signing up

**Date:** 2026-11-22<br/>
**Status:** Decided 2026-11-22: Cloudflare Turnstile only, no self-hosted provider for now;
[PQ1](#open-questions) and [PQ2](#open-questions) as recommended. Built as
[DW10](../plans/self-registration-is-a-chapter-not-a-trait.md#dw10-a-check-that-a-person-is-signing-up).<br/>
**Question:** Which provider checks that a person, not a script, is signing up? Recommended answer:
Cloudflare Turnstile as the hosted default on AWS, and ALTCHA's open-source proof of work, verified
inside the door's own function, for deployments that cannot send visitors to a third party.<br/>
**For:** [DW10: a check that a person is signing up](../plans/self-registration-is-a-chapter-not-a-trait.md#dw10-a-check-that-a-person-is-signing-up)
in the plan
[Self-registration is a chapter, not a trait](../plans/self-registration-is-a-chapter-not-a-trait.md#switching-it-on-and-off-and-the-aws-door--planned-2026-10-25).

---

## In plain words

A sign-up door on a public URL mails whatever address a caller types. A script can type a thousand
addresses of strangers. The plan closes that with four guards, and this document chooses the
provider for one of them: the check that a person is at the form.

Two kinds of check exist. A **hosted** check loads a script from a vendor, watches the browser for a
moment, and gives the form a token. The door sends the token to the vendor and gets yes or no. A
**proof of work** makes the browser do a few hundred milliseconds of arithmetic and send the result.
The door can check that result itself, with no vendor.

The two are not equally strong. A hosted check tries to tell a real browser from a script. A proof
of work only makes each sign-up cost some processor time, for a person and a script alike. It slows
a script down. It does not stop one. See
[What proof of work does not stop](#what-proof-of-work-does-not-stop).

The recommendation, in short:

- **Hosted default: Cloudflare Turnstile.** Free without a request cap, no puzzle, the usual
  verification call. Its weak point is privacy: the visitor's address goes to a US company.
- **Self-hosted: ALTCHA, open-source edition.** MIT for widget and server library, nothing to run
  beside the door's function, no outbound call.
- **One contract for both**, with one honest addition for proof of work: a second, small door that
  hands out the challenge.

The owner chose Turnstile alone, so the `challenge` member and the second door below are not
built. The answers to the questions are in [Open questions](#open-questions). The facts this analysis could not confirm are listed in
[What could not be verified](#what-could-not-be-verified).

## What the check has to do

From [DW10](../plans/self-registration-is-a-chapter-not-a-trait.md#dw10-a-check-that-a-person-is-signing-up)
and from
[The gap that must close before this ships anywhere public](../plans/self-registration-is-a-chapter-not-a-trait.md#the-gap-that-must-close-before-this-ships-anywhere-public):

1. The form sends a token. The sign-up door verifies it before it relays anything.
2. A missing or failed token is answered like every other sign-up and records nothing.
3. The local platform's provider always passes, so the laptop walk needs no vendor and no network.
4. The shell's `config.json` names the provider and its public site key. The secret is deployment
   configuration and never reaches the browser.
5. The framework is open source. Whatever the shell bundles and whatever the door imports must
   carry a licence that allows that.
6. The threat is narrow: a script signing strangers up so the deployment mails them. The check does
   not have to protect a login or a checkout.

## Hosted candidates

Options numbered PH1 to PH5. *PH* is short for *person check, hosted*.

| Id | Candidate | Puzzle | Server verification | Browser loads | EU position | Licence | Price | Against scripted sign-ups |
|---|---|---|---|---|---|---|---|---|
| PH1 | Cloudflare Turnstile | None in managed mode; at most a checkbox | `POST challenges.cloudflare.com/turnstile/v0/siteverify`, `secret` + `response`, optional `remoteip`. Token lives 300 s, single use | Script from `challenges.cloudflare.com`; about 85 kB by a competitor's count | US vendor. Collects IP, TLS fingerprint, user agent. Processor for detection, controller for improving it. Location not stated | Closed service; no client code to bundle | Free: unlimited challenges, 20 widgets, 10 hostnames each. Enterprise by quote | Good: judges the browser, not only its CPU |
| PH2 | hCaptcha | Image puzzle on Free. "99.9% Passive" on Pro, fully passive on Enterprise | `POST api.hcaptcha.com/siteverify`, form body, `secret` + `response`. Token lives 120 s, single use | Script from `js.hcaptcha.com`; 250 kB or more by a competitor's count | US vendor, says it is a processor. Regional endpoints on Enterprise only | Closed service | Free: $0. Pro: $139 a month ($99 yearly) for 100,000, then $0.99 per 1,000 | Good, but puzzle-free only when paid |
| PH3 | Friendly Captcha, hosted | None: proof of work plus risk signals | `POST global.frcapi.com/api/v2/captcha/siteverify`, header `X-API-Key`. EU: `eu.frcapi.com` | Vendor SDK, MPL-2.0, from npm or the vendor | German vendor. EU-only endpoint (hosted in Germany) from the Advanced plan | SDK MPL-2.0; service closed | Free: 1,000 a month, non-commercial only. €9 for 1,000, €39 for 5,000, €200 for 50,000 | Fair: proof of work with difficulty raised for suspect clients |
| PH4 | Google reCAPTCHA v3 and Enterprise | None; returns a score, the site sets the threshold | `siteverify` on `google.com` for v3; an assessment call in Google Cloud for the paid tiers | Script from Google; 300 kB or more by a competitor's count | US vendor. No EU-only option found. Sets cookies | Closed service | Free: 10,000 assessments a month per organization. Then $8 flat to 100,000, then $1 per 1,000 | Good, at the price of the widest data collection |
| PH5 | AWS WAF Challenge and CAPTCHA | Challenge: none. CAPTCHA: a puzzle | None in the door: the firewall checks its own token before the request arrives | AWS integration script, per web ACL | No new processor: stays with AWS in the deployment's region | Closed service | Web ACL $5 and $1 a rule a month, $0.60 per million requests. CAPTCHA $0.40 per 1,000 attempts. Challenge fee not confirmed | Fair: a silent browser challenge, not a person check |

Notes on what the table cannot hold.

**Turnstile ([PH1](#hosted-candidates)).** Cloudflare's plans page states "unlimited challenges"
on the free plan and WCAG 2.2 AAA conformance
([plans](https://developers.cloudflare.com/turnstile/plans/)). Older sources quote a cap of one
million verifications a month; the current page does not. Verification is the request shape that
hCaptcha, reCAPTCHA and Cap's server copy
([server-side validation](https://developers.cloudflare.com/turnstile/get-started/server-side-validation/)).
On `internal-error` Cloudflare says to retry, and offers an `idempotency_key` for that. It does not
say whether to fail open or closed. The privacy addendum names what is collected and the two roles
([Turnstile privacy addendum](https://www.cloudflare.com/turnstile-privacy-policy/)). It names no
processing location, so an EU operator must assume the visitor's address can leave the EU.

**hCaptcha ([PH2](#hosted-candidates)).** The puzzle-free modes are paid
([pricing](https://www.hcaptcha.com/pricing), [FAQ](https://docs.hcaptcha.com/faq),
[developer guide](https://docs.hcaptcha.com/)). The free plan
shows image puzzles, which [DW10](../plans/self-registration-is-a-chapter-not-a-trait.md#dw10-a-check-that-a-person-is-signing-up) rules out. Accessibility on the free plan is a text challenge or an
email-verified bypass, per the FAQ. That is a second sign-up to complete the first.

**Friendly Captcha ([PH3](#hosted-candidates)).** The only hosted candidate from an EU vendor. Two
things work against it as the framework's default. The free plan is for non-commercial use, and the
EU-only endpoint needs the €200 plan
([plans](https://friendlycaptcha.com/signup/),
[SDK](https://github.com/FriendlyCaptcha/friendly-captcha-sdk),
[EU endpoint](https://developer.friendlycaptcha.com/docs/v2/guides/eu-endpoint)). Its documentation
is the only one that says what to do when the vendor is down: accept the submission and alert
yourself ([verify](https://developer.friendlycaptcha.com/docs/v2/getting-started/verify)).

**reCAPTCHA ([PH4](#hosted-candidates)).** It answers with a score, not yes or no, so its provider
needs a threshold as extra configuration
([billing](https://docs.cloud.google.com/recaptcha/docs/billing-information),
[tiers](https://docs.cloud.google.com/recaptcha/docs/compare-tiers)). For an Austrian
operator it is the hardest to defend: the widest collection and cookies that need consent.

**AWS WAF ([PH5](#hosted-candidates)).** The honest answer on whether it can serve the door: yes,
with work, and it is not the check [DW10](../plans/self-registration-is-a-chapter-not-a-trait.md#dw10-a-check-that-a-person-is-signing-up) describes.

- The narrow door is an AppSync API called with `fetch` from a single-page app. A Challenge or
  CAPTCHA rule answers such a request with status 202 or 405 and the header `x-amzn-waf-action`.
  The page with the challenge is only sent to a request that accepts `text/html`
  ([action behavior](https://docs.aws.amazon.com/waf/latest/developerguide/waf-captcha-and-challenge-actions.html)).
  So the bare rule action blocks the shell and shows nothing.
- To pass, the shell must load AWS's integration script, obtain a token with it, and send the token
  with each call, as a cookie or as the header `x-aws-waf-token`
  ([client integrations](https://docs.aws.amazon.com/waf/latest/developerguide/waf-application-integration.html)).
  The shell and the API sit on different domains, so the web ACL needs a token domain list that
  names the shell's host
  ([token domains](https://docs.aws.amazon.com/waf/latest/developerguide/waf-tokens-domains.html)).
- The firewall verifies the token. The door never sees a verdict, so no scenario can assert it, and
  nothing of it fits a capability the door calls.
- Challenge is a silent browser check. CAPTCHA is a puzzle. Neither is a puzzle-free person check.

It is still worth keeping in view. It is the one hosted candidate that adds no processor, and
[DW6](../plans/self-registration-is-a-chapter-not-a-trait.md#dw6-the-limit-on-aws) already puts a
web ACL on the narrow API. See [PQ4](#open-questions).

## Self-hosted candidates

Options numbered PS1 to PS5. *PS* is short for *person check, self-hosted*.

| Id | Candidate | Licence | What must run | Server verification | Browser loads | Accessibility | State |
|---|---|---|---|---|---|---|---|
| PS1 | ALTCHA, open-source edition | MIT, widget and server libraries | Nothing new: a library call in the door's function | In process: recompute the signature with a secret key, check the work and the expiry, record the challenge as used | Widget bundled with the shell, 34 kB gzipped by its own count; no cookies | Claims WCAG 2.2 AA and the European Accessibility Act | Active; version 3 current |
| PS2 | mCaptcha | AGPL-3.0 server; client libraries permissive | Its own server with a database | HTTP call to that server | Widget in an iframe from that server | None stated | Before 1.0, "work in progress" by its own README |
| PS3 | Cap | Apache-2.0 | Its server `capd` with Valkey, or a core library with a store you supply | `POST /siteverify` on `capd`, same request shape as reCAPTCHA; or in process with the library | Widget about 20 kB, self-served; no cookies | None stated | Active; the older server library is marked legacy |
| PS4 | Friendly Captcha, self-hosted | Lite server: source-available, non-commercial. Full product: Enterprise only | A PHP server (lite) or a contract (Enterprise) | HTTP call to that server | The vendor's widget | Not checked | Lite: "small hobby projects" by its own README |
| PS5 | Our own proof of work | Ours | Nothing new | In process, a few dozen lines | A solver and a form control we write | Ours to build and audit | Does not exist |

Notes.

**ALTCHA ([PS1](#self-hosted-candidates)).** The open-source edition is the widget plus libraries;
the vendor's paid products (a hosted service and a self-hosted server named Sentinel) add risk
scoring and are not needed here
([open source and paid](https://altcha.org/docs/open-source-vs-paid/),
[repository](https://github.com/altcha-org/altcha)). The server signs each challenge with a secret
key. Verification is "entirely cryptographic and requires no API calls"
([server integration](https://altcha.org/docs/v2/server-integration)). The vendor's guidance is that
the server must keep a registry of solved challenges and refuse a second use
([security recommendations](https://altcha.org/docs/integration/security-recommendations/)). The
framework already has a store that hands a value over once: the stash. A flaw of exactly this kind
was fixed in the libraries in 2025 ([CVE-2025-68113](https://nvd.nist.gov/vuln/detail/CVE-2025-68113)),
so the library version must be pinned at or above the fix.

**mCaptcha ([PS2](#self-hosted-candidates)).** AGPL on a server the deployment would run next to an
open-source framework is workable but unwelcome: every deployer inherits the duty to offer the
server's source to its users. It is also before a stable release
([repository](https://github.com/mCaptcha/mCaptcha)). Not recommended.

**Cap ([PS3](#self-hosted-candidates)).** The strongest self-hosted candidate on paper. Besides
proof of work it runs "instrumentation challenges that verify the environment is a real browser"
([repository](https://github.com/tiagozip/cap), [guide](https://trycap.dev/guide/),
[its comparison](https://trycap.dev/guide/open-source-captcha)). That second layer lives in the
`capd` server, which needs a container and Valkey; the older in-process library
"only issues SHA-256 challenges, without HashWX or instrumentation"
([server library](https://trycap.dev/guide/server.html)). A serverless deployment has no place for a
long-running server, so Cap means a new kind of resource on the platform. A newer stateless core
library is said to run on Lambda; its documentation could not be read today.

**Friendly Captcha self-hosted ([PS4](#self-hosted-candidates)).** A "Friendly Lite" server exists
([repository](https://github.com/FriendlyCaptcha/friendly-lite-server)). Its README calls the
licence "a non-commercial source available license", which rules it out for a framework whose
deployers run shops. The full self-hosted endpoint is an Enterprise feature. Not an option.

**Our own ([PS5](#self-hosted-candidates)).** The server half is small: issue a signed challenge,
check a nonce, refuse a reuse. The cost is elsewhere. The browser half is a solver in a worker, a
form control with states a screen reader can follow, translations, and a difficulty that stays fair
on an old phone. ALTCHA has all of that under MIT, and its wire format is plain enough that the
door could verify it with its own few dozen lines if the library ever had to go. Writing our own
buys nothing ALTCHA does not already give.

## The capability

The idiom is in [`Capabilities.res`](../../reventless/spec/src/semantic/Capabilities.res): a record
the platform fills and hands to a door, with a provider record per capability, a named
`unavailable` value, and failures as a variant. [`Stash.res`](../../reventless/spec/src/semantic/Stash.res)
is the smallest example; [`Messaging.res`](../../reventless/spec/src/semantic/Messaging.res) shows a
provider that also publishes what it can do. A sketch in the same shape:

```rescript
// PersonCheck.res, in spec beside Stash.res
type failure =
  | Rejected(string) // the provider said no: missing, bad, expired or reused token
  | Unavailable(string) // the provider could not be asked

/** What the shell must know to render the widget. Public by construction. */
type widget = {
  provider: string, // "turnstile", "altcha", ...
  siteKey?: string,
}

type t = {
  verify: (~token: string, ~remoteIp: string=?) => promise<result<unit, failure>>,
  /** Proof of work only: a fresh signed challenge for the widget to solve. */
  challenge?: unit => promise<result<string, failure>>,
  /** Left out by a provider that needs no widget, as the local one. */
  widget?: widget,
}

let alwaysPasses: t = {verify: async (~token as _, ~remoteIp as _=?) => Ok()}
let unavailable = (~reason: string): t => {
  verify: async (~token as _, ~remoteIp as _=?) => Error(Unavailable(reason)),
}
```

`Capabilities.t` gains `personCheck: PersonCheck.t`, and `Capabilities.none` says `unavailable`.
The local platform passes `alwaysPasses`. `CapabilityNeed` gains an arm, so the door declares the
need and the deploy can refuse a self-service role without a provider, which is the refusal
[DW8](../plans/self-registration-is-a-chapter-not-a-trait.md#dw8-the-admission-check-and-the-shells-configuration-on-aws)
plans.

The shell's `config.json` carries the `widget` record and nothing else, under the existing
`selfRegistration` key:

```json
"personCheck": { "provider": "turnstile", "siteKey": "0x4AAAA..." }
```

No key means no widget and no token, which is what the local platform writes. The secret stays in
deployment configuration (`platform:personCheckSecret`, a Pulumi secret) and reaches only the door's
function.

**Which candidates fit without special cases.**

- [PH1](#hosted-candidates), [PH2](#hosted-candidates) and reCAPTCHA v3 from
  [PH4](#hosted-candidates) share one request shape: one provider module, three endpoints.
  reCAPTCHA adds a score threshold.
- [PH3](#hosted-candidates) differs by a header and a JSON body: a second, equally small module.
- [PS3](#self-hosted-candidates) with `capd` and [PS2](#self-hosted-candidates) are also
  `siteverify` calls and fit `verify` as hosted ones do. They need a server address in
  configuration, and a server.
- [PS1](#self-hosted-candidates) and [PS5](#self-hosted-candidates) fit `verify` and need the one
  addition in the sketch: `challenge`. The widget fetches it, so the narrow API of
  [DW5](../plans/self-registration-is-a-chapter-not-a-trait.md#dw5-a-narrow-door-for-visitors-on-aws)
  gains one more anonymous field. That call counts against the limit of
  [DW6](../plans/self-registration-is-a-chapter-not-a-trait.md#dw6-the-limit-on-aws) like the
  others, which the default of ten an hour must allow for. Single use comes from the stash:
  `challenge` puts the challenge's id, `verify` takes it, and a second take finds nothing.
- [PH5](#hosted-candidates) does not fit. Its verdict is never handed to the door.

**When the provider cannot be asked.** `Rejected` is answered like every other sign-up, as
[DW10](../plans/self-registration-is-a-chapter-not-a-trait.md#dw10-a-check-that-a-person-is-signing-up) says. `Unavailable` is a different fact and needs a decision: see [PQ2](#open-questions).

## Cost on AWS

**Per verification.** The door already runs in a function. A hosted check adds one outbound HTTPS
call to that run, so it adds duration, not an invocation. Lambda bills $0.0000166667 per GB-second
on x86 ([Lambda pricing](https://aws.amazon.com/lambda/pricing/)). Assuming 300 ms of waiting at
512 MB, that is about $0.0000025 a sign-up, or a quarter of a cent per thousand. The latency is an
assumption, not a measurement. The mail the sign-up then sends costs many times more. An in-process
proof of work adds a few milliseconds and two writes to the stash table.

**Egress.** A function outside a VPC reaches the internet with no extra resource. As far as the
code shows, the framework places a function in a VPC only when the deployment's event log is
Postgres (`~vpcConfig` in `RuntimeEnvironment_Lambda.res`). There, a function has no route out
until the VPC gets a NAT gateway, which costs roughly $0.045 to $0.05 an hour, some $33 to $38 a
month, plus a fee per gigabyte ([VPC pricing](https://aws.amazon.com/vpc/pricing/)). That fixed
cost dwarfs the checks themselves. Two ways around it:

- run the door's verification in a function that is not in the VPC, or
- use [PS1](#self-hosted-candidates), which calls nobody. It needs only DynamoDB, which a VPC
  reaches through a gateway endpoint at no charge.

**The vendor's bill.** For a deployment with a thousand sign-ups a month:
[PH1](#hosted-candidates) costs nothing, [PH4](#hosted-candidates) nothing,
[PH3](#hosted-candidates) €9 if commercial, [PH2](#hosted-candidates) nothing with puzzles or
$99 to $139 without, and [PS1](#self-hosted-candidates) nothing.

## What proof of work does not stop

A proof of work asks for processor time. A script has processor time. An attacker who accepts half
a second of CPU per sign-up, or who solves in native code instead of a browser, passes every pure
proof of work, [PS1](#self-hosted-candidates) and [PS5](#self-hosted-candidates) included. Raising
the difficulty hurts a person on an old phone before it hurts a rented server. So proof of work is a
price per request, not a person check.

Hosted checks are not a wall either. Paid solving services exist for all of them; they were not
priced for this analysis. A hosted check raises the cost per sign-up further than proof of work
does. Neither brings it to infinity.

That is why the plan has four guards, and why the door and its guards deploy together:

| Guard | What it bounds | What it leaves |
|---|---|---|
| The person check, [DW10](../plans/self-registration-is-a-chapter-not-a-trait.md#dw10-a-check-that-a-person-is-signing-up) | The cost of each scripted sign-up | A patient attacker who pays it |
| The limit per address, [DW6](../plans/self-registration-is-a-chapter-not-a-trait.md#dw6-the-limit-on-aws) | One source | Many sources |
| The bounded sender, [DW11](../plans/self-registration-is-a-chapter-not-a-trait.md#dw11-a-bounded-mail-sender) | The total mail in a day, whoever asks | A day's worth of unwanted mail, at the cap |
| The bill alarm, [DW12](../plans/self-registration-is-a-chapter-not-a-trait.md#dw12-an-alarm-on-the-bill) | How long anything runs unnoticed | Nothing; it tells a person |

With proof of work as the person check, the daily cap of
[DW11](../plans/self-registration-is-a-chapter-not-a-trait.md#dw11-a-bounded-mail-sender) carries more of the weight. A
deployment that chooses [PS1](#self-hosted-candidates) should keep that cap small.

## Recommendation

1. **Hosted default on AWS: Turnstile ([PH1](#hosted-candidates)).** It is the only hosted
   candidate that is puzzle-free, free for commercial use and without a stated cap. A framework
   default must not put a bill or a puzzle in front of every deployer. Its cost is privacy: a US
   processor that sees the visitor's address. The deployer must say so in its privacy notice, and
   the framework's guide must say that plainly.
2. **Self-hosted: ALTCHA open-source ([PS1](#self-hosted-candidates)),** verified in the door's
   function with the stash for single use. MIT throughout, nothing to run, no egress, and an
   accessible widget that exists today. It is the right answer for a deployer who may not use a US
   vendor, and for a function inside a VPC.
3. **Build the capability with the `challenge` member from the start,** so both providers are
   ordinary and neither is a special case.
4. **Friendly Captcha ([PH3](#hosted-candidates)) as a second hosted provider later,** if a
   deployer asks for an EU vendor and accepts the price. It is one small module once the capability
   exists.
5. **Not chosen:** hCaptcha (puzzle-free only when paid), reCAPTCHA (privacy), AWS WAF as the
   check (no verdict for the door), mCaptcha (AGPL, unfinished), Cap (needs a server), Friendly
   Lite (non-commercial), our own (an accessible widget is the real work).

An owner who weighs privacy above strength could make [PS1](#self-hosted-candidates) the default on
AWS too and offer Turnstile as the stronger choice. The capability is the same either way; only the
default in the platform's configuration differs. That is [PQ1](#open-questions).

## Open questions

Numbered PQ1 to PQ5. *PQ* is short for *person check question*.

**PQ1. Which provider is the default on AWS when the deployer names none?** Turnstile is stronger;
ALTCHA sends no visitor data anywhere and needs no account with a vendor. **Recommendation:** no
silent default. The deploy refuses a self-service role until `platform:personCheck` names a
provider, and the guide recommends Turnstile and says what it costs in privacy. A deployer then
chooses a processor knowingly, which GDPR asks of them anyway.

**PQ2. What does the door answer when the provider is `Unavailable`?** Fail open lets sign-ups
through unchecked, and a missing route out of a VPC would then switch the guard off without anyone
noticing. Fail closed "like every other sign-up" tells a real person to check a mailbox that stays
empty. **Recommendation:** fail closed and say so: an infrastructure rejection like `Throttled`,
which names no address and so is no oracle, plus a metric that raises the operator's alarm. The
other guards make fail open survivable, but silence is the worse failure here.

**PQ3. Does the door pass the visitor's address to a hosted provider?** `remoteip` is optional
everywhere. The vendor sees the address anyway when the browser loads the widget. Passing it lets
the vendor compare the two. **Recommendation:** do not pass it at first. It keeps the address out of
one more code path, in line with
[DW6](../plans/self-registration-is-a-chapter-not-a-trait.md#dw6-the-limit-on-aws) keeping it out of rows and logs, and can be added behind
configuration if abuse shows a need.

**PQ4. Should the web ACL of [DW6](../plans/self-registration-is-a-chapter-not-a-trait.md#dw6-the-limit-on-aws) also carry a WAF Challenge rule ([PH5](#hosted-candidates))?** It
would add a browser check with no new processor, in front of the function. It needs the AWS script
in the shell, a token domain list, and facts not confirmed today. **Recommendation:** not now.
Revisit after the walk of
[DW9](../plans/self-registration-is-a-chapter-not-a-trait.md#dw9-the-example-on-aws-and-the-walk),
with a short spike that proves the token passes AppSync from the shell's domain.

**PQ5. What difficulty does the proof of work start with?** Too low is no cost; too high locks out
slow phones. **Recommendation:** ALTCHA's default, as configuration beside the secret, with the
solve time measured in the walk on one old phone before any public window opens.

## What could not be verified

Stated here so nothing above reads as firmer than it is.

- **hCaptcha:** whether the free plan has a monthly cap (the pricing page states none; other sites
  say 10,000), its cookies, and where free-plan data is processed. Sources for these were
  competitors' pages.
- **Turnstile:** where visitor data is processed, the terms of Cloudflare's data processing
  agreement, and which cookies it sets. Cloudflare's own Turnstile privacy page in the developer
  documentation returned an error today. The 85 kB script size is ALTCHA's figure.
- **Friendly Captcha:** whether the global endpoint keeps addresses in the EU, the wording of its
  data processing agreement, its widget's size and accessibility, and what counts as a "request".
  Its pricing page URL returned an error; prices are from its sign-up page.
- **reCAPTCHA:** the v3 endpoint and its cookies are from memory, not checked today. One site says
  it is sold under a new product name since April 2026.
- **AWS WAF:** the fee per Challenge response; whether the integration script works with a plain
  Challenge rule or needs a paid managed rule group; whether AppSync accepts the
  `x-aws-waf-token` header across origins. No AWS page found today covers AppSync specifically.
- **Cap:** the stateless core library's interface (its page returned an error), and any
  accessibility statement.
- **ALTCHA:** the exact current version number and Sentinel's price. Its accessibility claim is the
  vendor's own; no independent audit was found.
- **mCaptcha:** the date of its last commit.
- **Friendly Lite:** its README gives two licence descriptions that do not match; either rules out
  commercial use.
- **AWS prices:** the NAT gateway rate for Frankfurt and the Lambda rate on arm64. Verification
  latency was assumed, not measured.
- **Solving services:** that they exist for every hosted check is common knowledge; no price was
  looked up.

Every source is linked where it is used. The AWS WAF prices are from its
[pricing page](https://aws.amazon.com/waf/pricing/).
