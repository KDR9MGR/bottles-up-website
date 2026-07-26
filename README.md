# BottlesUp Website

**Toronto's Premier Nightlife App Landing Page**

A professional landing page for BottlesUp - the ultimate VIP table booking and digital ticket platform for Toronto's hottest venues.

## 🌟 Features

- **Loading Video**: Custom loading experience with your brand video
- **Event Listings + Ticketing**: Events are managed in the CMS and sold via Stripe Checkout; buyers get an emailed e-ticket with a QR code
- **VIP Waitlist Signup**: Stored in Supabase and mirrored to Mailchimp, viewable in the CMS
- **CMS Panel** (`/cms`): manage events/tickets, view bookings, view the VIP list, edit footer/contact/social links and hero copy
- **SEO Optimized**: Complete meta tags, structured data, and sitemap
- **Mobile-First Design**: Responsive design that works on all devices
- **PWA Ready**: Installable web app with manifest and service worker ready
- **Professional Animations**: Smooth transitions and hover effects
- **Toronto-Focused**: Location-specific content for Toronto nightlife

## 🚀 Quick Start

### Development

```bash
# Install dependencies
npm install

# Copy env.example to .env and fill in your Supabase project's URL/anon key
cp env.example .env

# Start development server
npm run dev
```

Visit the printed local URL (Vite default is `http://localhost:5173`) to see your site.

The CMS lives at `/cms` (redirects to `/cms/login` if you're not signed in as a `cms_admins` user). See `supabase/migrations/` for schema and `supabase/functions/` for the Stripe/email/VIP-list backend - deploy with the Supabase CLI (`supabase link`, `supabase db push`, `supabase functions deploy`).

### Build for Production

```bash
npm run build
npm run preview
```

## 📁 Project Structure

```
bottlesup-website/
├── public/
│   ├── app_logo.svg          # Your BottlesUp logo (add this)
│   ├── loading_video.mp4     # Your loading video (add this)
│   ├── sitemap.xml          # SEO sitemap
│   ├── robots.txt           # Search engine instructions
│   └── manifest.json        # PWA manifest
├── src/
│   ├── components/          # Public site React components
│   │   ├── Header.tsx       # Navigation with logo
│   │   ├── Hero.tsx         # Main hero section (headline/subtext editable via CMS)
│   │   ├── Features.tsx     # Core features showcase
│   │   ├── PopularEvents.tsx # Published events from Supabase + booking dialog
│   │   ├── BookingDialog.tsx # Name/email/phone + ticket tier -> Stripe Checkout
│   │   ├── EmailCollection.tsx # VIP waitlist signup
│   │   └── Footer.tsx       # Footer with contact/social info from the CMS
│   ├── cms/                 # /cms admin panel (auth-gated)
│   │   └── pages/           # Dashboard, Events, Bookings, VIP List, Site Content
│   ├── pages/
│   │   ├── Index.tsx        # Main landing page
│   │   ├── BookingSuccess.tsx / BookingCancel.tsx # Stripe Checkout redirect targets
│   │   └── ...
│   └── lib/
│       └── supabase.ts      # Supabase client
├── supabase/
│   ├── migrations/          # Schema (events, orders, vip_emails, site_content, RLS)
│   └── functions/           # site-create-checkout-session, site-stripe-webhook, vip-subscribe, resend-ticket-email
├── vercel.json            # Vercel deployment config
└── DEPLOYMENT.md          # Deployment guide
```

## 🎨 Customization

### Adding Your Assets

1. **Logo**: Add `app_logo.svg` to the `public` folder
2. **Loading Video**: Add `loading_video.mp4` to the `public` folder
3. **Branding**: Update colors in `src/index.css` if needed

### CMS / Backend Setup

1. Create a Supabase project, apply `supabase/migrations/`, and deploy `supabase/functions/` (see `DEPLOYMENT.md`)
2. Add yourself to `cms_admins` (via the Supabase dashboard, after signing up a user for CMS login)
3. Set Stripe (`STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`), Resend (`RESEND_API_KEY`), and optionally Mailchimp secrets as Supabase Edge Function secrets - never in this repo's `.env`

## 🌐 Deployment

### Deploy to Vercel

1. **Push to GitHub**:
   ```bash
   git add .
   git commit -m "Ready for deployment"
   git push origin main
   ```

2. **Deploy to Vercel**:
   - Visit [vercel.com](https://vercel.com)
   - Import your GitHub repository
   - Configure build settings (automatically detected)
   - Deploy!

3. **Custom Domain** (Optional):
   - Add your domain in Vercel dashboard
   - Update DNS settings as instructed

See `DEPLOYMENT.md` for detailed deployment instructions.

## 📊 SEO Features

- ✅ **Meta Tags**: Complete Open Graph and Twitter Cards
- ✅ **Structured Data**: Schema.org markup for better search results
- ✅ **Sitemap**: XML sitemap for search engines
- ✅ **Robots.txt**: Search engine crawling instructions
- ✅ **Canonical URLs**: Proper URL canonicalization
- ✅ **Mobile Optimization**: Mobile-first responsive design

## 📱 Progressive Web App

- ✅ **Web App Manifest**: Installable on mobile devices
- ✅ **Theme Colors**: Branded colors for mobile browsers
- ✅ **App Shortcuts**: Quick access to key sections
- ✅ **Offline Ready**: Ready for service worker implementation

## 🔧 Technical Stack

- **React 18** with TypeScript
- **Vite** for fast development and building
- **Tailwind CSS** for styling
- **Shadcn/ui** for UI components
- **React Router** for navigation
- **Supabase** (Postgres + Auth + Storage) for the CMS, events, bookings, and VIP list
- **Supabase Edge Functions** for Stripe Checkout, the Stripe webhook, and VIP-list/Mailchimp sync
- **Stripe Checkout** for ticket payments
- **Resend** for e-ticket emails

## 📧 Contact & Support

For questions about the BottlesUp website:
- **Email**: hello@bottlesupapp.com
- **Developers**: dev@bottlesupapp.com

For venue partnerships and promoter inquiries:
- **Partners**: partners@bottlesupapp.com
- **Promoters**: promoters@bottlesupapp.com

## 🎯 Toronto Nightlife

This website is specifically designed for Toronto's vibrant nightlife scene, featuring:
- Entertainment District venues
- King Street West hotspots  
- Queen Street West locations
- Financial District bars
- Yorkville lounges
- And more across the GTA!

---

**Built for Toronto's Nightlife Revolution** 🍾
