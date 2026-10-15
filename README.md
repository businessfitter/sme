# Orzio

Your whole business, run by AI agents and approved by you. Eight industry editions (see below) and these modules:

| Module | What it covers |
|---|---|
| **Accounting** | Group consolidation (consolidated trial balance and statements, intercompany ledger and statements, FX translation under IAS 21, group adjustments and NCI), branch results, ledger, banking, assets and investments (with the agent's list of allowed investments for your country and industry), schedules, month-end close, tabbed financial statements under the framework you choose (IFRS, IFRS for SMEs, US GAAP, FRS 102, SOCPA, Ind AS, cash basis…) with the current period in bold against approved comparatives, Financial analysis (live ratios, variance, 1/3/5-year projections, sensitivity), budgets and forecasts |
| **Sales** | Quotes prepared by the agent from CRM or customers' requests, sent by link or portal, accepted or changed online; service agreements drafted by the agent, e-signed with the company stamp; invoices, customer payments, projects and billing, statements, aging, reminders, three-way match |
| **Procurement** | Suppliers, requests for quotation by link or portal, agent comparison, LPOs with approval, goods received, bills matched to LPO and receipt, payables reports (aging, supplier ledgers, commitments, GRNI, payment schedule) |
| **Inventory** | Item cards, stock and movements at weighted-average cost, warehouses (HQ, warehouse, store, fulfilment centre, 3PL, in transit), transfers through transit, stock counts (count → review → post), replenishment drafted by the inventory agent, landed costs, valuation and ageing |
| **E-commerce** (industry) | Live sales board, orders from your website, Shopify, WooCommerce, marketplaces (CSV), POS and phone, fulfilment (pick lists, labels, shipping), carriers with rate cards and COD remittances, stores and the embeddable live shop, catalogue for the web, pricing rules, channel and margin reports |
| **Help desk** | Help centre with FAQs, tickets from staff to your IT team with SLAs and internal notes, and escalation from the IT team to Orzio support |
| **HR** | Organogram drafted by the HR agent and approved by the HR Manager, payroll and employees, recruitment |
| **Employee Lounge** | Geo-verified check-in from the phone (500 m, server time), leave, requests, assigned tasks, daily and monthly summaries, performance reviews, the employee's library |
| **Patient Module** (medical clinics) | Front desk with appointments, online booking requests, tokens and a waiting-room queue screen. Doctor's desk with vitals, ICD-10 diagnosis, e-prescription (English and Urdu instructions), tests and procedures, agent-drafted notes and prescription checks (allergies, duplicates, pregnancy, child dosing, stock). Daily register with photo reading. Patient records with MR numbers and full history |
| **Clinic Module** (medical clinics) | Billing and cash counter (itemised bills, charity applied automatically, cash, card, wallet, panel/insurance), day closing with cash count. Pharmacy (starter formulary, batches, expiry, first-expiry-first-out dispensing, cost of medicines). Laboratory (results, normal ranges, flags, reports). Welfare assessments with committee approval. Charity funds and donations, donor dashboards, doctors and their fee share, clinic reports (ICD-10, notifiable diseases, missed follow-ups) |
| **CRM** | Pipeline and leads, customer and supplier queries, marketing, website |
| **Documents & e-sign** | Files, letters, e-signatures placed on the page, with or without a date-and-time stamp, saved signatures confirmed by an email code, manager approval before employees sign |
| **Tax** | VAT and corporate tax |
| **Compliance** | Law register built by the compliance agent and refreshed monthly, obligations and regulator due dates, licences and documents with expiry dates, AML screening against official sanctions lists (and World-Check One when connected), every module's policies and procedures, policy exceptions found in your transactions, monthly CEO summary |
| **Entity Risk Management** | Risk management policy, department risk registers, the entity register of key risks, risk appetite set by the CEO, key risk indicators from your data, ERM agent |
| **Internal Audit** | Activity logs, controls and period locks, access matrix and delegations, AI agents |

Every module has its own **Settings** (module, company, group and personal levels) and its own **Policies & risks**: a policies and procedures manual and a risk register (COSO 2013, COSO ERM, ISO 31000, IIA standards, IFRS and local law), reviewed by the agent every month, approved by the manager and then the CEO, and downloadable in Word and PDF. A **Knowledge library** in every login holds the manuals for that person's functions and industry knowledge for the country and internationally, and answers questions using the company's own records within the person's rights.

This edition is built to be sold. One codebase runs either way:

| Mode | Who it's for | How it behaves |
|---|---|---|
| **SaaS** (`mode = saas`, default) | Any business, self-serve | People sign up on your domain, create a **workspace** (one customer business), get a free trial, invite their team. Each workspace is walled off from every other one by the database. |
| **Dedicated install** (`mode = single`) | Larger or regulated clients | A separate Vercel + Supabase copy for one client. Only one workspace can exist, on the unlimited *Dedicated* plan. |

**Workspace vs company.** A workspace is the customer account you sell. Inside it, the app's own **Company** picker holds that customer's legal entities and branches (for example a UAE company and a KSA branch). Plans limit how many entities a workspace may have.

## What's in the folder

| Part | Runs on | What it does |
|---|---|---|
| `public/app.html` | Vercel (static) | The app (served at `/` and `/app`; at `/app` only on the website domain) |
| `public/claude-shim.js` | Vercel (static) | Connects the app to Supabase. Handles sign-up, workspace setup, the workspace switcher, plan and usage, and trial/read-only notices |
| `public/admin.html` | Vercel (static), at `/admin` | **Your** console: all customers, plans, trials, usage, suspend/activate |
| `public/vendor/` | Vercel (static) | Supabase client library, bundled so the app doesn't depend on a public CDN |
| `public/brand/` | Vercel (static) | Orzio logo, app icons and favicons (SVG + PNG); `logo.svg` / `logo-white.svg` for your website and documents |
| `public/site.webmanifest` | Vercel (static) | Lets phones add Orzio to the home screen with its icon |
| `api/ai.js` | Vercel function | Calls Claude with your Anthropic key after checking workspace status, the per-person rate limit and the plan's monthly AI quota, and logs usage |
| `api/[route].js` + `api/_routes/` | One Vercel function | Runs the smaller endpoints below (Vercel's Hobby plan allows 12 functions per deployment; this keeps Orzio at 4) |
| `api/_routes/blob.js` | via `api/[route].js` | Opens uploaded files with a two-minute signed link, only for people allowed to see them |
| `api/_routes/config.js` | Vercel function | Gives the browser the public settings (never the secret keys) |
| `api/_routes/sign.js` | Vercel function | Email codes for signing and saving signatures; records the one-use signing attestation |
| `api/_routes/quote.js`, `public/q.html` | Vercel function + page | Customers open, accept or ask for changes to a quote from the link, without logging in |
| `api/_routes/rfq.js`, `public/r.html` | Vercel function + page | Suppliers submit quotations from the link |
| `api/_routes/email.js`, `api/_mail.js` | Vercel function | Sends quotes, agreements, statements and RFQs by email (Resend), capped per workspace per day |
| `api/reminders.js` | Vercel Cron, daily | Payment reminders before and after due dates |
| `api/sanctions.js` | Vercel Cron, daily | Downloads the official sanctions lists for AML screening |
| `api/_routes/worldcheck.js` | Vercel function | Optional LSEG World-Check One screening |
| `public/sw.js` | Browser | Makes Orzio installable on phones and desktops |
| `api/_routes/store.js`, `public/store.js`, `public/shop.html`, `public/track.html` | Vercel function + pages | Your customers' online shop: live catalogue and stock, orders that reserve stock at once, order tracking, Shopify/WooCommerce order webhooks |
| `api/_routes/connector.js` | Vercel function | Pushes stock levels to Shopify and WooCommerce |
| `api/_routes/contact.js` | Vercel function | The website's contact form |
| `public/site/` | Vercel (static) | The Orzio marketing website (home, product, industries, pricing, security, partners, about, contact, privacy, terms) |
| `supabase/migrations/0001_init.sql` | Supabase | Database, access rules, plans, limits, usage log, file storage, admin functions |

## 1. Put it on GitHub

Create a **private** repository (for example `orzio`) and upload the contents of this folder, or:

```bash
cd orzio
git init && git add . && git commit -m "Orzio commercial edition"
git branch -M main
git remote add origin https://github.com/<you>/orzio.git
git push -u origin main
```

## 2. Set up Supabase

1. Create a project at [supabase.com](https://supabase.com). For UAE/GCC customers pick Frankfurt or Mumbai, and check your customers' data-residency needs (see the launch checklist).
2. **SQL Editor**: paste all of `supabase/migrations/0001_init.sql` and press **Run**.
3. **Authentication → URL Configuration**: set **Site URL** to your domain (step 3) and add `https://<your-domain>/**` under **Redirect URLs**. Password-reset links come back to `/?reset`.
4. **Authentication → Providers → Email**: keep **Confirm email** on.
5. **Authentication → Email Templates → Magic Link**: add the one-time code so people can confirm signatures, for example `Your Orzio code is {{ .Token }}`. (Codes for signing use this template.)
6. **Authentication → SMTP Settings**: connect your own email sender (for example Resend, Postmark or Amazon SES). Supabase's built-in sender only allows a few emails an hour and is not meant for production. Without your own sender, sign-up confirmations will stall once real customers arrive.
7. **Project Settings → API**: copy the **Project URL**, the **anon public** key and the **service_role** key.

## 3. Deploy on Vercel

1. **Add New → Project**, import the repository. Framework preset **Other**, no build command. Use a **Pro** team. AI agents reading long documents can take minutes, and `vercel.json` allows them 300 seconds, which the Hobby plan doesn't permit.
2. **Environment Variables** (see `.env.example`):
   - `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`
   - `ANTHROPIC_API_KEY`, needed for the AI agents
   - `TERMS_URL`, `PRIVACY_URL`: links shown at sign-up. Leave them empty until your legal pages exist.
   - `APP_NAME`: the product name shown on sign-in and in the admin console (default `Orzio`)
   - `GOOGLE_MAPS_API_KEY` (optional): a browser key for the office-location maps and address search. Restrict it to your domain in Google Cloud and enable *Maps JavaScript API* and *Places API*. Without it the maps and the address search use OpenStreetMap (free, no key).
   - `RESEND_API_KEY` and `EMAIL_FROM` (optional but recommended): to email quotes, agreements, statements, requests for quotation and payment reminders from the server (resend.com; `EMAIL_FROM` like `Orzio <billing@yourdomain.com>` on a verified domain). Without them the app opens the user's own email program with the message ready.
   - `CRON_SECRET`: any long random text. Vercel sends it to `/api/reminders` every morning (see `vercel.json`, `crons`) so payment reminders go out automatically.
   - `APP_URL`: your site address, e.g. `https://orzio.ai/app`, used in reminder emails.
   - `UAE_LOCAL_LIST_URL` (optional): a CSV export of the UAE Local Terrorist List if you host one. Otherwise upload the EOCN Excel in Compliance → AML screening.
   - `WC1_API_KEY`, `WC1_API_SECRET`, `WC1_GROUP_ID` (optional): LSEG World-Check One credentials. Built to LSEG's published API but not tested without credentials.
3. **Deploy**, then add your domain under **Settings → Domains**.

## 4. Make yourself platform admin

1. Open your site, create your account and set up a workspace (for example your own company, or a demo).
2. In Supabase **SQL Editor** run:
   ```sql
   insert into public.platform_admins (user_id)
   select id from auth.users where email = 'you@yourdomain.com';
   ```
3. Open `https://<your-domain>/admin`. In **Settings**, set `support_email`. Customers see a **Contact us** button with it when a trial ends or they want to change plan.

## 5. Running the business from `/admin`

- **Customers**: every workspace with owner email, plan, status, trial end, team and portal logins, AI calls and tokens this month, storage, record count and last activity. Click a row to change the plan, activate, suspend or cancel, extend a trial (+7/+14 days), override limits for that customer only, or keep internal notes. **Export CSV** for your records.
- **Plans**: edit limits and prices, or add plans. Prices are blank until you decide them. Once set, customers see them in **Plan and usage** and the console shows monthly recurring revenue.
- **Settings**: trial length, mode, how many workspaces one person may create (stops endless free trials), AI calls per minute per person, support email.

Billing isn't connected yet: when a customer pays you (for example by invoice), open their row and set **Plan** and **Status = active**. Connecting Stripe later only needs a small webhook function that sets `plan` and `status` on the `orgs` table with the service role key.

The console shows metadata and usage only. You cannot read customers' books from it, and the database enforces that.

### What each status means

| Status | Customer can read | Customer can change data | AI agents |
|---|---|---|---|
| `trial` (before end date) | Yes | Yes | Yes |
| `trial` (after end date) | Yes | **No** (read-only notice shown) | No |
| `active` | Yes | Yes | Yes |
| `past_due` (grace) | Yes | Yes | Yes |
| `suspended` | Yes | **No** | No |
| `cancelled` | **No** | No | No |

Data is never deleted by a status change.

### Default plans (edit in /admin → Plans)

| Plan | Team logins | Employee/customer/supplier logins | Entities | AI calls / month | AI tokens / month | Records | Files |
|---|---|---|---|---|---|---|---|
| Free trial (14 days) | 3 | 25 | 3 | 300 | 2 M | 250 MB | 1 GB |
| Starter | 3 | 50 | 1 | 1,500 | 15 M | 1 GB | 5 GB |
| Growth | 10 | 250 | 3 | 6,000 | 60 M | 5 GB | 25 GB |
| Scale | 30 | 1,000 | 10 | 20,000 | 200 M | 20 GB | 100 GB |
| Dedicated (single installs) | unlimited | unlimited | unlimited | unlimited | unlimited | unlimited | unlimited |

Limits are enforced by the database and the AI function. When a customer hits one, they see a clear message ("Your plan allows 3 team logins…"). Notes:
- **AI tokens** are what Anthropic bills you for, so they're the real cost cap. Calls stop a burst of small requests. Free trials and portal users never reach the most expensive model, and each call is capped in size and reply length.
- **Records** is the size of the books themselves (every entry, invoice, employee…). Saving a smaller version or deleting always works, even when a workspace is over its limit.
- Employees, customers and suppliers can store at most 2,000 items of up to 64 KB each in their own portal.


## Agents first, people review

The agents prepare the work and people approve, amend or delete it:

- The **Review hub** (top bar, *Review*) lists everything the agents prepared that needs a person: journal entries, statement packs, projections, the investment list, quotes, agreements, policy updates, the organogram, policy exceptions and possible sanctions matches.
- It shows the share of posted entries the agents prepared in the last 30 days, against a 70% target.
- **Financial analysis** fills the projection assumptions from your last 12 months. Anything a person changes is marked *Edited*.
- The **investment agent** builds the list of allowed instruments from the company's country, industry, regulated status and Sharia setting. You can add your own lines; it reviews the list monthly, and a person approves it.


## Medical clinics

Set the company's industry to **Medical clinic** (or Healthcare). Two modules appear: **Patient Module** and **Clinic Module**.

**How a visit flows**

1. **Front desk.** Find or register the patient and issue a token for a doctor; the token slip prints. Patients get an MR number (MR-000001…), and the front desk can record vitals. Appointments booked by phone or online show up here too. A full-screen queue view can run on a TV in the waiting area.
2. **Doctor's desk.** The doctor calls the next token and sees allergies, long-term conditions, vitals with warnings and recent visits. They record the complaint, examination and an ICD-10 diagnosis, then write the prescription.
   - Quantities are worked out from dose × frequency × days, and instructions print in English and Urdu.
   - The doctor ticks tests and procedures and sets a follow-up date.
   - The agent can draft the note from short notes. It checks the prescription for allergies, duplicate groups, ulcer + NSAID, pregnancy, child doses and stock.
   - "Finish" sends the patient to billing, the pharmacy and the lab.
3. **Billing & cash.** The bill is built automatically: consultation fee, procedures, tests and dispensed medicines. Approved welfare patients get their charity share automatically. Payment can be cash, card, bank, wallet or a panel/insurance account, and a receipt prints.
4. **Pharmacy.** Dispense paid prescriptions first-expiry-first-out. Receive stock by batch and expiry, and watch low stock and expiring medicines.
5. **Laboratory.** Enter results; values outside the normal range are flagged, and the doctor is notified. Print the report or send the patient a link.
6. **Close the day.** Count the cash. The agent posts one entry for the day:
   - cash, bank and panel receipts
   - charity from each fund
   - income split into consultations (4000), medicines (4100), tests (4150) and procedures (4200)
   - cost of medicines dispensed (5000 / 1200)

**Welfare.** Staff record household size, income and circumstances. The agent suggests a charity share from the clinic's bands; the welfare committee approves it, and the approval lasts 6 months by default.

**Doctors.** Each doctor has a fee, working days and hours, and a share % of consultation fees. The agent books the monthly share for approval.

**Patient links.** A prescription, visit summary or lab report can be sent as a link (`/p?t=…`, valid 7 days), with a WhatsApp button.

**Online booking.** Turn it on in Clinic Module → Settings → Prescription and welfare. Patients use `/b?t=…` to ask for a day and doctor, and the front desk confirms. Requests are rate-limited.

**Roles.** Clinic manager, doctor, nurse, pharmacist, lab technician, receptionist and cashier, each with matching access. Give these roles in Settings → Logins and access.

**Charity funds and donor dashboards.** Donations go into restricted funds (Zakat 3500, General 3510) and charity care is paid out of them. Public donor dashboards (`/d?t=…`) show totals only and expire after 7 days by default.

Not included yet: e-claims to insurers (for example DHA eClaimLink or Riayati in the UAE) and national health-record exchange (NABIDH, Malaffi). Panel billing exports a claims list for now.

## Custom domains (white-label)

A workspace owner can open Orzio on their own address. Go to **Settings → Group → Your own domain**, then enter for example `app.theirclinic.org`. They then add the DNS records shown and press **Check**. On that address, the sign-in page shows their name and opens their workspace.

To switch this on for your server, add these Vercel environment variables:

- `VERCEL_TOKEN`: a Vercel access token with access to this project.
- `VERCEL_PROJECT_ID`: Vercel → Project → Settings → General → Project ID.
- `VERCEL_TEAM_ID`: only if the project belongs to a team.

Email sign-in links (magic links and invitations) only redirect to addresses Supabase allows. For each verified customer domain, add `https://their-domain/**` under Supabase → Authentication → URL Configuration → Redirect URLs. Password sign-in works without this.

## Employee check-in (geo-fenced) — how it is protected

- Each company sets its office locations in **Employee Lounge → Settings → Office locations** (map, 500 m radius by default, up to 1 km).
- On the phone the employee picks the office and presses **Check in**. The **database** reads its own clock, measures the distance to the office and refuses anything outside the radius or less precise than the limit (±100 m by default). Refused attempts are logged.
- Nobody can insert, edit or delete a check-in directly, not even the owner. Corrections are separate records with a reason. There is no front-desk check-in button: a day only counts as present from a verified phone check-in or an HR correction with a reason (shown as *Corrected*).
- HR places each office by searching its address (for example *Johar Town, Lahore*), then fine-tunes the pin on the map. Employees get a *Get directions* link to their office.
- The first phone is registered; another phone is flagged, or refused when *phone registration* is on. HR can reset it.
- Far from the office? The screen says so and opens Leave with *Work from another location*.
- Limits: a browser cannot detect a rooted phone that fakes GPS. The server-side radius, precision limit, phone registration, impossible-travel flags and the HR review of flags make this much harder, but if you need certainty add a selfie or a kiosk at the door.

## Signatures

- Mark where each person signs on the PDF. Choose: date and time printed with the signature, no stamp, or the signer chooses.
- Every signature is confirmed with a code sent to the signer's email (Supabase Auth email, see step 2.5). Saved signatures are stored only after a code and used only with a code. The server records a one-use attestation (server time, document and signature fingerprints).
- Documents sent to an employee need their manager's approval before the employee can sign.
- Agreements signed by the company carry the company stamp (upload yours in Sales → Settings or use the generated digital stamp).
- These are simple electronic signatures with a tamper-evident audit trail, not qualified signatures (UAE PASS / eIDAS QES).

## AML screening

The server downloads the official, free sanctions lists every night (`/api/sanctions`, Vercel Cron): UN Security Council consolidated list, US OFAC SDN (with aliases), UK Sanctions List (FCDO) and the EU consolidated financial sanctions list. The UAE Local Terrorist List is published by the EOCN (uaeiec.gov.ae) as Excel/PDF without a stable file address, so upload it in Compliance → AML screening (or set `UAE_LOCAL_LIST_URL`). The platform admin can refresh the lists by calling `/api/sanctions` with their login.

Customers, suppliers, employees, leads and the shareholders/UBOs you list are screened by name with fuzzy matching, monthly and on demand. Possible matches go to the Compliance Manager, who confirms (and the CEO is told) or clears them with a reason. A name match is not an identification: confirm with date of birth, nationality and documents. World-Check One is LSEG's paid database; it is used only when you add your own credentials.

## Installing on phones

Orzio is an installable web app. On Android/Chrome an **Install app** button appears; on iPhone use Share → *Add to Home Screen*. It opens full-screen with the Orzio icon. Data always comes live from the server.

## Groups, HQ and company logins

Every workspace is the group's **HQ**. Under it, Settings → Organisation adds companies (subsidiaries with ownership %, associates), branches and sales points.

- **Who sees what.** Workspace settings → *HQ access* sets each person's role, whether they see *All companies (HQ)* or only ticked companies, and whether they see the *Consolidated* view. Each company's own settings → *Company access* gives a person a different role in that company, or removes them. A subsidiary's staff who are given only that company see only that company; the database enforces it.
- **Dashboard.** People with access to more than one company get tiles to switch between each company and the consolidated group.
- **Consolidation** lives in Accounting → Group: consolidated TB and statements, intercompany ledger and statements, FX rates (closing, average; save per period), and group adjustments. The agent prepares eliminations, investment/equity and NCI entries; a person approves them. Export the full pack to Excel.
- **Point of sale** per sales point, with a daily closing that posts to the branch.

## E-commerce, inventory and online stores

Choose *E-commerce* as the industry (or turn the module on) and open E-commerce → Stores.

1. **Your own website.** Each store has a key. Paste the snippet shown on the store card into any page (`<div data-orzio-shop></div>` plus `store.js`): customers see live stock, order, and stock is reserved at once. Or link to the hosted shop page. Customers track orders at `/track`.
2. **Shopify / WooCommerce.** On the store card, enter the shop address and access token, then add an order webhook pointing at `https://<your-app>/api/store?key=STORE_KEY&src=shopify` (or `src=woo`) with the webhook secret you saved. Orders arrive in Orzio; stock is pushed back from the store card or after each shipment.
3. **Carriers.** E-commerce → Shipping holds rate cards (presets for Aramex, DHL, SMSA, Naqel, SPL, Emirates Post, FedEx, UPS, J&T, TCS, Leopards, PostEx and own delivery). Labels are printed from the order; COD remittances are recorded there.

When an order ships, Orzio posts the sale, VAT, cost of goods, shipping and fees to the ledger.

## Help desk

Staff open tickets in Help desk. Your **IT support** role works the queue, can turn an answer into an FAQ, and can escalate to Orzio support. You answer escalations in `/admin → Support`.

## The Orzio website

`public/site/` is the marketing website. Before launch:

- Replace the placeholders: `hello@orzio.ai` and `sales@orzio.ai`, the office location, prices ("Ask for a quote"), social links (empty), in the pages under `public/site/` (search and replace across the folder).
- Have a lawyer review `privacy.html` and `terms.html`.
- Set `CONTACT_EMAIL` (and `RESEND_API_KEY`) so the contact form reaches you.
- **Domains.** On `orzio.ai` and `www.orzio.ai`, `/` is the website and the app is at `/app`. On every other address (your `*.vercel.app` address, customers' own domains, an `app.` subdomain if you add one) `/` opens the app, as before. In Supabase → Authentication → URL Configuration, add `https://orzio.ai/**` to the redirect URLs so sign-up and password-reset links return to `/app`. If your domain isn't orzio.ai, change the two `host` values in `vercel.json` and the `og:image` address in the pages.
- Until the domain is set, the website is at `https://<your-app>/site/`.

## Workspace home and companies

After signing in, everyone lands on the **workspace home**: a block for each company they can open, the **consolidated group** (when there are two or more companies) and, for the workspace admin, **Create a company**. There are no figures on this page.

- **Create a company** asks for the country, company type, financial year end, industry (editions first), sub-industry and number of employees. The setup agent then populates the company from the published Orzio industry pack for that industry and country.
- **Opening a company** shows its modules. *All companies* (or *Companies* in the top bar) returns to the workspace home.
- **Workspace settings** (workspace admin only): choose the admins of each company, including yourself. A company admin manages that company’s settings, logins and modules. Invite people in Logins and access first.

## Industry editions

Eight editions package Orzio for one industry each, on the same platform and database:

| Edition | For | Edition modules |
|---|---|---|
| Orzio Clinic | Medical and welfare clinics | Patient Module, Clinic Module |
| Orzio Broker | Insurance brokers | Broking: placements and quote comparison, policies and debit notes, client money, remittances, endorsements, renewals, claims, production and commission |
| Orzio Commerce | E-commerce | E-commerce, Inventory |
| Orzio Software | Software houses | Software: subscriptions, billing run, deferred revenue (IFRS 15), SaaS metrics, R&D capitalisation (IAS 38); Practice; Projects |
| Orzio Consulting | Management consultancies | Practice: engagements, acceptance checks, letters, WIP, utilisation, month-end WIP accrual; Projects |
| Orzio Practice | Accounting practices | Practice plus clients and services, jobs and statutory deadlines, document requests |
| Orzio Fire & Safety | Fire protection contractors | Fire & safety: sites and asset register, AMC contracts, visit planner, job cards with standards-based checklists, certificates, compliance reports |
| Orzio Holdings | Holding companies | Holdings: portfolio and valuation, dividends, intercompany loans and interest, management fees, governance; Group consolidation |

A company’s industry decides its edition. Each edition switches on its modules (Settings → Modules can change this) and adds its own roles, policies and risk register.

## Industry packs (prepared once per industry and country)

Customers do not trigger an AI setup run each. Instead:

1. In `/admin → Industry packs`, choose an industry and a country and press **Run the agents**. The agents prepare 11 sections: country profile (tax rates, banks, exchange rate), chart of accounts, laws and due dates, licences, catalogue, checklists, templates, edition settings, policies, KPIs and help desk answers. This uses the `ANTHROPIC_MODEL_COMPLEX` model.
2. Review each section, edit its JSON if needed, **Approve** it, then **Publish**. Publishing a new version retires the previous one.
3. Every customer in that industry and country is offered the pack: at sign-up (the setup step uses it instead of an agent run) and in each company’s **Settings → Industry edition and pack**, where the company’s owner, admin or CEO approves it before it is applied. Applying only adds; nothing the customer entered is changed.
4. Customers whose country has no pack yet get the standard template, and their request appears in the admin console so you can prepare one. A pack for country `*` is the fallback for all countries.

Countries with a published pack are added to the sign-up country list automatically.

## Updating an existing installation

When a new version changes `supabase/migrations/0001_init.sql`, run the whole file again in the Supabase SQL Editor. It is written to be re-run safely: it keeps all data and only adds or replaces rules and functions.

## 6. How customers use it

1. **Sign up** at your domain → **Set up your workspace** (name) → the setup wizard builds their company, chart of accounts and taxes (the trade licence upload is optional; progress is saved, so leaving half-way resumes on the same step). After that, everyone lands on the **executive dashboard**; the **Modules** tab in the top bar opens every module.
2. **Invite people**: the person creates an account at your domain and confirms their email first. The owner then opens **Settings → Logins and access**, types the person's full email, and picks a role. The person sees **You're invited**, and nothing in the workspace is visible to them until they press **Accept**. Partial searches only show people already in that workspace. A full-email lookup shows only the email, never the person's name, and is limited to 30 an hour. So nobody can browse or harvest your other customers' users.
3. **Switch workspaces** (accountants serving several clients, groups) from the workspace button next to **Sign out**. The same button shows **Plan and usage**.

## Who can do what (enforced by the database, not just the screen)

| Role in the app | Database role | Can |
|---|---|---|
| Owner (whoever created the workspace) | owner | Everything, including granting and removing logins |
| Admin preset, accountant, finance lead, tax consultant, custom | staff | Read and change the books. **Cannot** grant logins; only the owner can. |
| Auditor | viewer | Read everything, change nothing |
| Employee, customer, supplier | portal | Only their own dashboard (`portal/<their id>/…`) and files shared to it |

**Companies (entities) per login.** In **Settings → Logins and access**, each staff login is given *All companies* (including ones added later) or a chosen set, e.g. only the KSA company of a group. This is enforced by the database: records of other companies never reach that person, and they cannot create or move records into them. A record belongs to the company in its `entity` field; records without one belong to the main company. Shared set-up (group settings, journals, workflows, exchange rates) is visible to every staff login.

The finer per-area tick boxes in **Logins and access** (view/edit/approve/delete per module) are applied by the app's screens. The database enforces the four roles above, isolation between workspaces, read-only status and plan limits. The access log is append-only, so even the owner cannot edit or delete it.

## Dedicated install for one client

Do steps 1–3 with the client's own GitHub repo, Supabase project and Vercel project (and their Anthropic key if they're paying for AI directly). Before anyone signs up, run in SQL Editor:

```sql
update public.platform_config set value = 'single' where key = 'mode';
```

The first person to sign up sets up the workspace on the unlimited Dedicated plan. Everyone else waits to be given access. Make yourself platform admin on that install too (step 4) if you're supporting it.

## Security notes

- The service role key and the Anthropic key stay on the server. The browser only gets the public anon key.
- Every record carries its workspace ID. Postgres row-level security checks each read and write against the person's role in that workspace.
- Files sit in a private bucket under `assets/<workspace>/<file>`. Staff open them through `/_blob/<id>` with a two-minute signed link. Employees, customers and suppliers can only open files referenced in their own portal records.
- AI calls are checked against the person's membership, the workspace status, a per-person rate limit counted in the database (so it holds across all servers), and the plan's monthly quota. Portal users never reach the most expensive model. Every call is logged with its token use.
- Realtime delete events carry only an opaque row ID, so they reveal nothing about other workspaces.
- People only join a workspace by accepting an invitation, and their profile email always comes from their verified sign-in email.
- Anonymous visitors can't call any database function. Signed-in users can't look up another workspace's status or limits.
- Writes inside one workspace are processed one at a time while limits are checked. That's invisible at SME scale, but very large bulk imports run sequentially.
- Turn on multi-factor authentication for your own admin account in Supabase.

## Launch checklist

- [ ] Own SMTP sender connected in Supabase (step 2.5)
- [ ] Terms of Service and Privacy Policy written (cover the UAE PDPL, and GDPR if you sell to the EU), `TERMS_URL` / `PRIVACY_URL` set
- [ ] A data-processing agreement for business customers. Name Supabase, Vercel and Anthropic as sub-processors.
- [ ] Data residency confirmed for regulated customers. Some UAE/KSA clients may need data kept in-country, which suits a dedicated install in their chosen region.
- [ ] Supabase on a paid plan with daily backups (point-in-time recovery for peace of mind)
- [ ] Monthly spend limit set on your Anthropic account
- [ ] `support_email` set in /admin → Settings, and plan prices decided
- [ ] `vercel.json` ships a **report-only** Content-Security-Policy. After a week with no violations in the browser console, rename the header to `Content-Security-Policy` to enforce it.
- [ ] A test customer taken through sign-up → setup wizard → invite → trial end → activation on your live domain

## Roles and access

The person who creates the workspace is the **Admin**. Position roles (CEO, CFO, Compliance Manager, Internal Audit Manager, Financial Accountant, HR Manager, department manager, officer) come with access presets you can adjust per module (view, edit, approve, delete), per company, with an end date and an approval limit. The CEO sees every module and log, can grant logins (not their own), gives final approval of policies, and receives the agent's daily summary. Delegations lend rights for a period and are recorded by the database. **Internal Audit → Settings → Access matrix** shows everyone's rights at a glance.

## Known limits of this release

- No automatic billing yet. Plans and activation are set by you in /admin.
- No self-serve workspace deletion. Set a customer to `cancelled` in /admin. Deleting their data for good is done in Supabase.
- The Outlook mailbox panel in CRM isn't connected in self-hosting. The Email, WhatsApp, Call and meeting buttons work.
- Data entered in the Claude-hosted version isn't copied over automatically.
- Carrier booking APIs aren't connected: rates come from your rate cards and labels are printed by Orzio; book pickups in the carrier's portal.
- Stock is pushed to Shopify/WooCommerce when someone uses the app (after a shipment, receipt or from the store card), not by a 24/7 background job.
- Live screens refresh every 15 seconds when realtime isn't available.
- Marketplace orders (Amazon, Noon and others) are imported from their CSV exports.
