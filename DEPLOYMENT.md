# BottlesUp Website Deployment Guide

## 🚀 Deploying to Vercel

This guide will help you deploy your BottlesUp website to Vercel with proper configuration.

### Prerequisites

1. **GitHub Repository**: Push your code to a GitHub repository
2. **Vercel Account**: Sign up at [vercel.com](https://vercel.com)
3. **Required Files**: Ensure you have these files in your `public` folder:
   - `app_logo.svg` (your BottlesUp logo)
   - `loading_video.mp4` (your loading video)

### Step-by-Step Deployment

#### 1. **Prepare Your Files**
```bash
# Make sure these files are in your public folder:
public/
├── app_logo.svg          # Your BottlesUp logo
├── loading_video.mp4     # Your loading video
├── sitemap.xml          # SEO sitemap (already created)
├── robots.txt           # Search engine instructions (already created)
└── manifest.json        # PWA manifest (already created)
```

#### 2. **Push to GitHub**
```bash
git add .
git commit -m "Ready for Vercel deployment"
git push origin main
```

#### 3. **Deploy to Vercel**

**Option A: Using Vercel CLI**
```bash
# Install Vercel CLI
npm i -g vercel

# Login to Vercel
vercel login

# Deploy
vercel

# Follow the prompts:
# - Link to existing project? No
# - Project name: bottlesup-website
# - Directory: ./
# - Build command: npm run build
# - Output directory: dist
```

**Option B: Using Vercel Dashboard**
1. Go to [vercel.com/dashboard](https://vercel.com/dashboard)
2. Click "New Project"
3. Import your GitHub repository
4. Configure:
   - **Project Name**: `bottlesup-website`
   - **Root Directory**: `./`
   - **Build Command**: `npm run build`
   - **Output Directory**: `dist`
   - **Install Command**: `npm install`

#### 4. **Environment Variables** (Vercel - client-side only)
Add these in Project Settings → Environment Variables (also see `env.example`):
```
VITE_SUPABASE_URL=https://your-project-ref.supabase.co
VITE_SUPABASE_ANON_KEY=your_anon_key_here
```

#### 4b. **Supabase Backend Setup** (one-time, not a Vercel env var)
The CMS, events, bookings, and VIP list live in a Supabase project (`supabase/` in this repo):

1. `supabase link --project-ref your-project-ref` (requires the Supabase CLI and an access token)
2. `supabase db push` to apply `supabase/migrations/`
3. Insert your admin user's `auth.users.id` into `cms_admins` so you can log into `/cms`
4. `supabase functions deploy site-create-checkout-session site-stripe-webhook vip-subscribe resend-ticket-email`
5. Set Edge Function secrets (`supabase secrets set ...`), never in this repo:
   ```
   STRIPE_SECRET_KEY=sk_live_or_test...
   STRIPE_WEBHOOK_SECRET=whsec_...       # from the Stripe webhook endpoint you create pointing at site-stripe-webhook
   RESEND_API_KEY=re_...
   TICKETS_FROM_EMAIL=tickets@yourdomain.com   # must be a Resend-verified sending domain
   SITE_URL=https://your-production-domain     # used for Stripe Checkout success/cancel redirects
   MAILCHIMP_API_KEY / MAILCHIMP_SERVER_PREFIX / MAILCHIMP_LIST_ID   # optional, mirrors VIP signups
   ALLOWED_ORIGIN=https://your-production-domain   # optional, restricts CORS on public functions
   ```
6. In the Stripe dashboard, add a webhook endpoint pointing at the deployed `site-stripe-webhook` function URL, subscribed to `checkout.session.completed`

#### 5. **Custom Domain** (Optional)
1. Go to Project Settings → Domains
2. Add your custom domain (e.g., `bottlesupapp.com`)
3. Follow Vercel's DNS configuration instructions

### ✅ What's Already Configured

- **Client-side routing**: `vercel.json` handles SPA routing (no 404 on refresh)
- **Security headers**: CSP, XSS protection, and other security headers
- **Caching**: Optimized caching for assets and static files
- **SEO**: Meta tags, Open Graph, Twitter Cards, and structured data
- **PWA**: Web app manifest for mobile installation
- **Performance**: Preconnect headers and optimized asset loading

### 🔍 Verification After Deployment

1. **Test Routing**: Navigate to different sections and refresh the page
2. **Check SEO**: Use tools like:
   - [Google PageSpeed Insights](https://pagespeed.web.dev/)
   - [Open Graph Debugger](https://developers.facebook.com/tools/debug/)
   - [Twitter Card Validator](https://cards-dev.twitter.com/validator)
3. **Mobile Experience**: Test on mobile devices
4. **PWA Features**: Try installing the app on mobile

### 🛠 Troubleshooting

**404 Errors on Refresh**
- ✅ Already handled by `vercel.json` rewrites

**Slow Loading**
- Make sure `app_logo.svg` is optimized
- Compress `loading_video.mp4` if it's too large

**Missing Favicon**
- Ensure `app_logo.svg` is in the `public` folder
- Clear browser cache

**SEO Issues**
- Verify all meta tags are properly filled
- Check `sitemap.xml` is accessible at `/sitemap.xml`
- Ensure `robots.txt` is accessible at `/robots.txt`

### 📈 Post-Deployment Optimization

1. **Analytics**: Add Google Analytics or Vercel Analytics
2. **Performance Monitoring**: Use Vercel's built-in performance metrics
3. **SEO Monitoring**: Submit sitemap to Google Search Console
4. **Social Media**: Test social sharing and preview cards

### 🌟 Production URLs

After deployment, your site will be available at:
- **Vercel subdomain**: `https://bottlesup-website.vercel.app`
- **Custom domain** (if configured): `https://bottlesupapp.com`

Your BottlesUp website is now ready to capture Toronto's nightlife enthusiasts! 🍾 