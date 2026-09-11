import { Instagram, Twitter, Facebook, Linkedin, Mail, Phone, MapPin, ArrowUpRight } from 'lucide-react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { useSiteContent } from '@/hooks/useSiteContent';

const Footer = () => {
  const content = useSiteContent();
  const location = useLocation();
  const navigate = useNavigate();

  // Same cross-page section nav fix as Header: these targets are homepage
  // sections, so a plain hash link would hard-reload the app from other pages.
  const goToSection = (id: string) => (e: React.MouseEvent) => {
    e.preventDefault();
    if (location.pathname === '/') {
      document.getElementById(id)?.scrollIntoView({ behavior: 'smooth' });
    } else {
      navigate(`/#${id}`);
    }
  };

  const linkClass = 'group inline-flex items-center gap-1 text-gray-400 transition-colors hover:text-orange-500';

  return (
    <footer className="border-t border-white/10 bg-black pb-8 pt-20 lg:pt-24">
      <div className="container mx-auto px-4 lg:px-6">
        <div className="mb-14 grid gap-10 md:grid-cols-2 lg:grid-cols-4">
          {/* Brand */}
          <div className="space-y-4">
            <div className="flex items-center space-x-2.5">
              <img src="/app_logo.svg" alt="BottlesUp Logo" className="h-8 w-8" />
              <span className="text-xl font-bold text-gradient">BottlesUp</span>
            </div>
            <p className="leading-relaxed text-gray-400">{content.footer_tagline}</p>
            <div className="flex gap-3 pt-1">
              {content.social_instagram && (
                <a
                  href={content.social_instagram}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="flex h-9 w-9 items-center justify-center rounded-full border border-white/10 bg-white/5 text-gray-400 transition-all duration-300 hover:-translate-y-0.5 hover:border-orange-500/40 hover:text-orange-500"
                >
                  <Instagram className="h-4 w-4" />
                </a>
              )}
              {content.social_twitter && (
                <a
                  href={content.social_twitter}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="flex h-9 w-9 items-center justify-center rounded-full border border-white/10 bg-white/5 text-gray-400 transition-all duration-300 hover:-translate-y-0.5 hover:border-orange-500/40 hover:text-orange-500"
                >
                  <Twitter className="h-4 w-4" />
                </a>
              )}
              {content.social_facebook && (
                <a
                  href={content.social_facebook}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="flex h-9 w-9 items-center justify-center rounded-full border border-white/10 bg-white/5 text-gray-400 transition-all duration-300 hover:-translate-y-0.5 hover:border-orange-500/40 hover:text-orange-500"
                >
                  <Facebook className="h-4 w-4" />
                </a>
              )}
              {content.social_linkedin && (
                <a
                  href={content.social_linkedin}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="flex h-9 w-9 items-center justify-center rounded-full border border-white/10 bg-white/5 text-gray-400 transition-all duration-300 hover:-translate-y-0.5 hover:border-orange-500/40 hover:text-orange-500"
                >
                  <Linkedin className="h-4 w-4" />
                </a>
              )}
            </div>
          </div>

          {/* For Users */}
          <div>
            <h3 className="mb-5 text-sm font-semibold uppercase tracking-wide text-white">For Users</h3>
            <ul className="space-y-3">
              <li><Link to="/events" className={linkClass}>Browse Events</Link></li>
              <li><Link to="/vip-tables" className={linkClass}>VIP Tables</Link></li>
              <li><Link to="/venues" className={linkClass}>Venues</Link></li>
              <li><Link to="/my-tickets" className={linkClass}>Digital Tickets</Link></li>
              <li><a href="/#waitlist" onClick={goToSection('waitlist')} className={linkClass}>Join Waitlist</a></li>
            </ul>
          </div>

          {/* For Partners */}
          <div id="partners">
            <h3 className="mb-5 text-sm font-semibold uppercase tracking-wide text-white">For Partners</h3>
            <ul className="space-y-3">
              <li><a href="mailto:partners@bottlesupapp.com" className={linkClass}>Venue Partnership</a></li>
              <li><a href="mailto:promoters@bottlesupapp.com" className={linkClass}>Promoter Portal</a></li>
              <li><a href="mailto:events@bottlesupapp.com" className={linkClass}>Event Listing</a></li>
              <li><a href="mailto:business@bottlesupapp.com" className={linkClass}>Business Inquiries</a></li>
            </ul>
          </div>

          {/* Contact Info */}
          <div>
            <h3 className="mb-5 text-sm font-semibold uppercase tracking-wide text-white">Contact Us</h3>
            <div className="space-y-3">
              {content.address && (
                <div className="flex items-center gap-3 text-gray-400">
                  <MapPin className="h-4 w-4 shrink-0 text-orange-500" />
                  <span className="text-sm">{content.address}</span>
                </div>
              )}
              {content.contact_email && (
                <div className="flex items-center gap-3">
                  <Mail className="h-4 w-4 shrink-0 text-orange-500" />
                  <a href={`mailto:${content.contact_email}`} className="text-sm text-gray-400 transition-colors hover:text-orange-500">
                    {content.contact_email}
                  </a>
                </div>
              )}
              {content.contact_phone && (
                <div className="flex items-center gap-3">
                  <Phone className="h-4 w-4 shrink-0 text-orange-500" />
                  <a href={`tel:${content.contact_phone}`} className="text-sm text-gray-400 transition-colors hover:text-orange-500">
                    {content.contact_phone}
                  </a>
                </div>
              )}
            </div>

            {/* Quick Contact for Partners */}
            <div className="mt-6 rounded-2xl border border-white/10 bg-white/[0.03] p-4 backdrop-blur-xl">
              <h4 className="mb-1.5 text-sm font-semibold text-orange-500">Partners &amp; Promoters</h4>
              <p className="mb-3 text-xs text-gray-400">Want to list your venue or event?</p>
              <a
                href="mailto:partners@bottlesupapp.com"
                className="inline-flex items-center gap-1 rounded-full bg-gradient-orange px-4 py-1.5 text-xs font-bold text-black transition-transform duration-300 hover:scale-105"
              >
                Get Started
                <ArrowUpRight className="h-3 w-3" />
              </a>
            </div>
          </div>
        </div>

        {/* Toronto Neighborhoods */}
        <div className="mb-10 border-t border-white/10 pt-10">
          <h3 className="mb-5 text-center text-sm font-semibold uppercase tracking-wide text-white">
            Serving Toronto's Hottest Neighborhoods
          </h3>
          <div className="flex flex-wrap justify-center gap-3">
            {[
              'Entertainment District',
              'King Street West',
              'Queen Street West',
              'Financial District',
              'Yorkville',
              'Distillery District',
              'Liberty Village',
            ].map((neighborhood) => (
              <span
                key={neighborhood}
                className="rounded-full border border-white/10 bg-white/[0.03] px-4 py-1.5 text-sm text-gray-400 transition-colors duration-300 hover:border-orange-500/30 hover:text-orange-500"
              >
                {neighborhood}
              </span>
            ))}
          </div>
        </div>

        <div className="flex flex-col items-center justify-between gap-4 border-t border-white/10 pt-8 md:flex-row">
          <p className="text-sm text-gray-500">
            © {new Date().getFullYear()} BottlesUp. All rights reserved. Toronto's Premier Nightlife App.
          </p>
          <div className="flex flex-wrap justify-center gap-6">
            <Link to="/privacy-policy" className="text-sm text-gray-400 transition-colors hover:text-orange-500">
              Privacy Policy
            </Link>
            <Link to="/my-tickets" className="text-sm text-gray-400 transition-colors hover:text-orange-500">
              My Tickets
            </Link>
            <a href="#" className="text-sm text-gray-400 transition-colors hover:text-orange-500">
              Terms of Service
            </a>
            <a href="#" className="text-sm text-gray-400 transition-colors hover:text-orange-500">
              Support
            </a>
          </div>
        </div>
      </div>
    </footer>
  );
};

export default Footer;
