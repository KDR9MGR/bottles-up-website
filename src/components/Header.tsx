import { useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { Menu, X } from 'lucide-react';

const navLinkClass =
  'relative text-sm font-medium text-gray-300 transition-colors hover:text-white after:absolute after:-bottom-1 after:left-0 after:h-px after:w-0 after:bg-gradient-orange after:transition-all after:duration-300 hover:after:w-full';

const Header = () => {
  const [isMenuOpen, setIsMenuOpen] = useState(false);
  const location = useLocation();
  const navigate = useNavigate();

  // Features/Events/Partners are sections on the homepage, not standalone pages.
  // A plain <a href="#id"> only works while already on "/" - from any other page
  // it's a dead click (there's no matching id on that page). Navigate home with
  // the hash first, then scroll, so these links work from anywhere in the app.
  const goToSection = (id: string) => (e: React.MouseEvent) => {
    e.preventDefault();
    setIsMenuOpen(false);
    if (location.pathname === '/') {
      document.getElementById(id)?.scrollIntoView({ behavior: 'smooth' });
    } else {
      navigate(`/#${id}`);
    }
  };

  const handleLogoClick = (e: React.MouseEvent) => {
    setIsMenuOpen(false);
    // React Router's <Link> is a no-op when already on the target route, so
    // clicking the logo while already on "/" would otherwise do nothing.
    if (location.pathname === '/') {
      e.preventDefault();
      window.scrollTo({ top: 0, behavior: 'smooth' });
    }
  };

  return (
    <header className="fixed top-0 left-0 right-0 z-50 border-b border-white/10 bg-black/50 backdrop-blur-2xl">
      <div className="container mx-auto px-4 lg:px-6">
        <div className="flex h-20 items-center justify-between py-3">
          {/* Logo */}
          <Link
            to="/"
            onClick={handleLogoClick}
            className="group flex items-center space-x-2.5 transition-transform duration-300 hover:scale-[1.03]"
          >
            <img src="/app_logo.svg" alt="BottlesUp Logo" className="h-8 w-8" />
            <span className="text-xl font-bold tracking-tight text-gradient">BottlesUp</span>
          </Link>

          {/* Desktop Navigation */}
          <nav className="hidden items-center gap-9 md:flex">
            <a href="/#features" onClick={goToSection('features')} className={navLinkClass}>
              Features
            </a>
            <a href="/#events" onClick={goToSection('events')} className={navLinkClass}>
              Events
            </a>
            <Link to="/vip-tables" className={navLinkClass}>
              VIP Tables
            </Link>
            <a href="/#how-it-works" onClick={goToSection('how-it-works')} className={navLinkClass}>
              How It Works
            </a>
            <a href="/#partners" onClick={goToSection('partners')} className={navLinkClass}>
              Partners
            </a>
          </nav>

          {/* Desktop CTA */}
          <div className="hidden items-center gap-3 md:flex">
            <Button
              variant="ghost"
              className="text-sm text-gray-300 hover:bg-white/5 hover:text-white"
            >
              Promoter Login
            </Button>
            <Button
              onClick={() => window.open('https://vendor.bottlesupapp.com/', '_blank')}
              variant="outline"
              className="rounded-full border-orange-500/60 text-orange-500 transition-all duration-300 hover:border-orange-500 hover:bg-orange-500/10 hover:text-orange-400"
            >
              Be Partner
            </Button>
            <Button className="rounded-full bg-gradient-orange border-0 font-bold text-black shadow-lg shadow-orange-500/20 transition-all duration-300 hover:scale-105 hover:shadow-orange-500/40">
              Join Waitlist
            </Button>
          </div>

          {/* Mobile Menu Button */}
          <button
            className="rounded-full p-2 text-white transition-colors hover:bg-white/10 md:hidden"
            onClick={() => setIsMenuOpen(!isMenuOpen)}
            aria-label="Toggle menu"
          >
            {isMenuOpen ? <X className="h-6 w-6" /> : <Menu className="h-6 w-6" />}
          </button>
        </div>

        {/* Mobile Menu */}
        {isMenuOpen && (
          <div className="animate-fade-in mb-4 rounded-2xl border border-white/10 bg-black/80 p-5 backdrop-blur-2xl md:hidden">
            <nav className="flex flex-col gap-4">
              <a href="/#features" onClick={goToSection('features')} className="text-gray-300 transition-colors hover:text-orange-500">
                Features
              </a>
              <a href="/#events" onClick={goToSection('events')} className="text-gray-300 transition-colors hover:text-orange-500">
                Events
              </a>
              <Link to="/vip-tables" onClick={() => setIsMenuOpen(false)} className="text-gray-300 transition-colors hover:text-orange-500">
                VIP Tables
              </Link>
              <a href="/#how-it-works" onClick={goToSection('how-it-works')} className="text-gray-300 transition-colors hover:text-orange-500">
                How It Works
              </a>
              <a href="/#partners" onClick={goToSection('partners')} className="text-gray-300 transition-colors hover:text-orange-500">
                Partners
              </a>
              <div className="flex flex-col gap-2 pt-3">
                <Button variant="outline" className="rounded-full border-orange-500/60 text-orange-500 hover:bg-orange-500/10">
                  Promoter Login
                </Button>
                <Button
                  onClick={() => window.open('https://vendor.bottlesupapp.com/', '_blank')}
                  variant="outline"
                  className="rounded-full border-orange-500/60 text-orange-500 hover:bg-orange-500/10"
                >
                  Be Partner
                </Button>
                <Button className="rounded-full bg-gradient-orange border-0 font-bold text-black">
                  Join Waitlist
                </Button>
              </div>
            </nav>
          </div>
        )}
      </div>
    </header>
  );
};

export default Header;
