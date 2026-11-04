# Auth e-mail templates

Supabase's dashboard does not read these files. They are the source of truth kept in git; paste the contents by hand (nothing here is applied by a deploy).

| File | Dashboard place | Subject |
|---|---|---|
| `magic-link.html` | Authentication > Emails > Magic Link | Your BottlesUp sign-in link |
| `recovery.html` | Authentication > Emails > **Reset Password** | Reset your BottlesUp password |

## Reset password (`recovery.html`)

One template for the whole project, with two automatic variants. The apps pass a `redirectTo` when they ask for a reset, Supabase gives the one it accepted back to the template as `.RedirectTo`, and the template picks its wording from it:

| App | `redirectTo` it sends | E-mail says |
|---|---|---|
| BottlesUp (customers) | `https://www.bottlesupapp.com/reset-password?app=user` | "your BottlesUp account", button and code |
| BottlesUp Business | `https://www.bottlesupapp.com/reset-password?app=business` | "your BottlesUp Business account", "Business" tag |
| anything else | none, or an address Supabase did not accept | the neutral BottlesUp wording |

The button goes to `https://www.bottlesupapp.com/reset-password` (`src/pages/ResetPassword.tsx`) with `token_hash`. It does NOT go through Supabase's own verify address, so opening the link (or a mail scanner doing it) spends nothing; the token is used only when the person submits the new password. The 6-digit code in the same e-mail (`{{ .Token }}`) is for typing into the app.

To switch it on, in this order (a reset e-mail sent before the page exists would lead nowhere):

1. Deploy this branch's website, so `/reset-password` is live.
2. Authentication > URL Configuration > Redirect URLs: add both addresses from the table above, exactly. (Without them the variants fall back to the neutral wording; the e-mail still works.) The old `bottlesup://reset-password` entry is no longer needed.
3. Authentication > Emails > Reset Password: set the subject, paste `recovery.html` in full.
4. Authentication > Emails > SMTP Settings: send from BottlesUp's own address instead of Supabase's shared one. With Resend: host `smtp.resend.com`, port `465`, username `resend`, password = a Resend API key with sending access, sender `no-reply@bottlesupapp.com` (the domain must be verified in Resend; the ticket e-mails already send from it), sender name `BottlesUp`. Then Authentication > Rate Limits: raise "e-mails sent per hour" as needed.
5. Check Authentication > Providers > Email: "Email OTP expiration" (the e-mail says the link and code "expire soon"; change the wording if you want to state the time) and the minimum password length (the apps and the page ask for at least 8 characters).
6. Send yourself a reset from each app and open the e-mail on a phone and on a computer.

`tests/edge/recoveryEmailTemplate.test.ts` reads this file and renders every variant, so a pasted-in change that breaks a link, drops the code or leaves template syntax behind fails the suite.
