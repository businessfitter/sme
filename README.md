# Orzio

Your whole business, run by AI agents and approved by you: accounting, sales and purchases, banking, payroll, recruitment, attendance, projects, documents and e-signatures, CRM, marketing, website, reports and tax, in one app.

This edition is built to be sold. One codebase runs either way:

| Mode | Who it's for | How it behaves |
|---|---|---|
| **SaaS** (`mode = saas`, default) | Any business, self-serve | People sign up on your domain, create a **workspace** (one customer business), get a free trial, invite their team. Each workspace is walled off from every other one by the database. |
| **Dedicated install** (`mode = single`) | Larger or regulated clients | A separate Vercel + Supabase copy for one client. Only one workspace can exist, on the unlimited *Dedicated* plan. |

**Workspace vs company.** A workspace is the customer account you sell. Inside it, the app's own **Company** picker holds that customer's legal entities and branches (for example a UAE company and a KSA branch). Plans limit how many entities a workspace may have.

## What's in the folder

| Part | Runs on | What it does |
|---|---|---|
| `public/index.html` | Vercel (static) | The app |
| `public/claude-shim.js` | Vercel (static) | Connects the app to Supabase. Handles sign-up, workspace setup, the workspace switcher, plan and usage, and trial/read-only notices |
| `public/admin.html` | Vercel (static), at `/admin` | **Your** console: all customers, plans, trials, usage, suspend/activate |
| `public/vendor/` | Vercel (static) | Supabase client library, bundled so the app doesn't depend on a public CDN |
| `public/brand/` | Vercel (static) | Orzio logo, app icons and favicons (SVG + PNG); `logo.svg` / `logo-white.svg` for your website and documents |
| `public/site.webmanifest` | Vercel (static) | Lets phones add Orzio to the home screen with its icon |
| `api/ai.js` | Vercel function | Calls Claude with your Anthropic key after checking workspace status, the per-person rate limit and the plan's monthly AI quota, and logs usage |
| `api/blob/[id].js` | Vercel function | Opens uploaded files with a two-minute signed link, only for people allowed to see them |
| `api/config.js` | Vercel function | Gives the browser the public settings (never the secret keys) |
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
5. **Authentication → SMTP Settings**: connect your own email sender (for example Resend, Postmark or Amazon SES). Supabase's built-in sender only allows a few emails an hour and is not meant for production. Without your own sender, sign-up confirmations will stall once real customers arrive.
6. **Project Settings → API**: copy the **Project URL**, the **anon public** key and the **service_role** key.

## 3. Deploy on Vercel

1. **Add New → Project**, import the repository. Framework preset **Other**, no build command. Use a **Pro** team. AI agents reading long documents can take minutes, and `vercel.json` allows them 300 seconds, which the Hobby plan doesn't permit.
2. **Environment Variables** (see `.env.example`):
   - `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`
   - `ANTHROPIC_API_KEY`, needed for the AI agents
   - `TERMS_URL`, `PRIVACY_URL`: links shown at sign-up. Leave them empty until your legal pages exist.
   - `APP_NAME`: the product name shown on sign-in and in the admin console (default `Orzio`)
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

## 6. How customers use it

1. **Sign up** at your domain → **Set up your workspace** (name) → the app's own setup wizard builds their company, chart of accounts and taxes.
2. **Invite people**: the person creates an account at your domain and confirms their email first. The owner then opens **Settings → Logins and access**, types the person's full email, and picks a role. The person sees **You're invited**, and nothing in the workspace is visible to them until they press **Accept**. Partial searches only show people already in that workspace. A full-email lookup shows only the email, never the person's name, and is limited to 30 an hour. So nobody can browse or harvest your other customers' users.
3. **Switch workspaces** (accountants serving several clients, groups) from the workspace button next to **Sign out**. The same button shows **Plan and usage**.

## Who can do what (enforced by the database, not just the screen)

| Role in the app | Database role | Can |
|---|---|---|
| Owner (whoever created the workspace) | owner | Everything, including granting and removing logins |
| Admin preset, accountant, finance lead, tax consultant, custom | staff | Read and change the books. **Cannot** grant logins; only the owner can. |
| Auditor | viewer | Read everything, change nothing |
| Employee, customer, supplier | portal | Only their own dashboard (`portal/<their id>/…`) and files shared to it |

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

## Known limits of this release

- No automatic billing yet. Plans and activation are set by you in /admin.
- No self-serve workspace deletion. Set a customer to `cancelled` in /admin. Deleting their data for good is done in Supabase.
- The Outlook mailbox panel in CRM isn't connected in self-hosting. The Email, WhatsApp, Call and meeting buttons work.
- Data entered in the Claude-hosted version isn't copied over automatically.
