# Auth + Email Setup (app.spinvibes.com)

> Record of Supabase auth/email configuration done 2026-06-12 (session 38).
> **None of this lives in code**: it's dashboard config. If the Supabase project is ever recreated, redo all of it.
> Supabase project: `zairvjyiwhajsulefyoi` (SpinvibesGOLF / TappingGlass org)

---

## Why this exists

Beta tester Mike (Yahoo Mail) hit two failures on 6/12:

1. **Magic link redirected to `localhost:3000`**: Site URL was still the Supabase default and the redirect allowlist was empty, so `emailRedirectTo` was ignored.
2. **`otp_expired` on first click**: Yahoo/Outlook scan links in incoming email by prefetching them. Supabase magic links are one-time GET URLs, so the scanner consumed the token before Mike ever tapped it.

---

## 1. URL Configuration (Auth → URL Configuration)

| Setting | Value |
|---|---|
| Site URL | `https://app.spinvibes.com` |
| Redirect URLs | `https://app.spinvibes.com/**`, `https://golf.spinvibes.com/**` |

If a new domain ever sends auth emails (e.g. spinvibes.com itself), add it to the allowlist or links will fall back to Site URL.

## 2. Scanner-proof magic links

- **Email template** (Auth → Emails → Magic link or OTP), subject `Sign in to SpinVibes Golf`, body links to:

  ```
  {{ .SiteURL }}/confirm.html?token_hash={{ .TokenHash }}&type=email&next={{ .RedirectTo }}
  ```

- **`confirm.html`** (this repo) shows a branded "Open My SpinVibes App" button. The token is only verified (`supabase.auth.verifyOtp`) on a human tap, prefetch scanners do a bare GET and never consume it. After verify it redirects to `next` (same-origin only).
- Do **not** revert the template to `{{ .ConfirmationURL }}`, that re-breaks Yahoo users.

## 3. Custom SMTP via Resend (Auth → Emails → SMTP Settings)

| Setting | Value |
|---|---|
| Sender | `SpinVibes Golf <guide@spinvibes.com>` |
| Host / Port | `smtp.resend.com` / `465` |
| Username | `resend` |
| Password | Resend API key, created 6/12 **specifically for Supabase** |
| Rate limit | 30 emails/hour (adjustable in dashboard) |

Two separate Resend keys exist on purpose:

- **Supabase SMTP key**: auth emails (magic links). Lives only in Supabase dashboard.
- **Netlify key** (`RESEND_API_KEY` env var), `send-guide-email` function on spinvibes-golf.netlify.app (the "your app is ready" email from the wizard). Revoking one does not affect the other.

## 4. Related code (this repo)

- `confirm.html`, tap-to-verify page (anti-scanner).
- `sw.js` v2, **network-first for HTML**, cache-first for assets. Deploys now reach installed users without cache-version bumps (v1 was cache-first on index.html, which silently pinned users to stale builds forever).
- `index.html`, light mode: `body.sv-light` CSS variable overrides + localStorage persistence (`sv-light-mode`). The ☀️ toggle was a no-op before 6/12.

## 5. Wizard handoff (golf-guide-builder repo)

`generateGuide()` flow: wizard → coaching plan → PIN setup → Supabase insert → **immediate redirect** to `app.spinvibes.com?u=<UUID>`. The old below-the-fold success screen is dead code (`showAppReady`). The `.wiz-body` container must stay in the hide selectors, it was missing, which made the wizard appear to "reset" after generating.
