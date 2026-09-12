import { useEffect, useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { Menu, X, LayoutDashboard, User, Ticket, LogOut } from 'lucide-react';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import { useUserAuth, userSignOut } from '@/hooks/useUserAuth';
import UserAuthModal from '@/components/UserAuthModal';
import Magnetic from '@/components/motion/Magnetic';

const navLinkClass =
  'relative text-sm font-medium text-gray-300 transition-colors hover:text-white after:absolute after:-bottom-1 after:left-0 after:h-px after:w-0 after:bg-gradient-orange after:transition-all after:duration-300 hover:after:w-full';

const Header = () => {
  const [isMenuOpen, setIsMenuOpen] = useState(false);
  const [authOpen, setAuthOpen] = useState(false);
  const [scrolled, setScrolled] = useState(false);
  const [scrollProgress, setScrollProgress] = useState(0);
  const location = useLocation();
  const navigate = useNavigate();
  const { session, profile } = useUserAuth();

  useEffect(() => {
    const onScroll = () => {
      const y = window.scrollY;
      const max = document.documentElement.scrollHeight - window.innerHeight;
      setScrolled(y > 12);
      setScrollProgress(max > 0 ? (y / max) * 100 : 0);
    };
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  }, []);

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
    if (location.pathname === '/') {
      e.preventDefault();
      window.scrollTo({ top: 0, behavior: 'smooth' });
    }
  };

  const handleSignOut = async () => {
    await userSignOut();
    navigate('/');
  };

  const initials = session
    ? (profile?.name ?? session.user.email ?? '?')
        .split(' ')
        .map((w) => w[0])
        .join('')
        .toUpperCase()
        .slice(0, 2)
    : '';

  return (
    <>
      <header
        className={`fixed top-0 left-0 right-0 z-50 border-b backdrop-blur-2xl transition-colors duration-300 ${
          scrolled ? 'border-white/10 bg-black/80' : 'border-white/5 bg-black/50'
        }`}
      >
        <div className="container mx-auto px-4 lg:px-6">
          <div
            className={`flex items-center justify-between gap-6 py-3 transition-[height] duration-300 ${
              scrolled ? 'h-16' : 'h-20'
            }`}
          >
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
              <Link to="/events" className={navLinkClass}>
                Events
              </Link>
              <Link to="/vip-tables" className={navLinkClass}>
                VIP Tables
              </Link>
              <Link to="/venues" className={navLinkClass}>
                Venues
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
                variant="brandOutline"
              >
                Be Partner
              </Button>

              {/* User auth */}
              {session ? (
                <DropdownMenu>
                  <DropdownMenuTrigger asChild>
                    <button className="h-9 w-9 rounded-full bg-gradient-to-br from-orange-500 to-orange-600 text-black text-sm font-bold flex items-center justify-center hover:opacity-90 transition-opacity overflow-hidden">
                      {profile?.avatar_url ? (
                        <img src={profile.avatar_url} alt="" className="h-full w-full object-cover" />
                      ) : (
                        initials
                      )}
                    </button>
                  </DropdownMenuTrigger>
                  <DropdownMenuContent align="end" className="w-48 bg-zinc-950 border-white/10 text-white">
                    <DropdownMenuLabel className="text-gray-400 font-normal text-xs truncate">
                      {profile?.name ?? session.user.email}
                    </DropdownMenuLabel>
                    <DropdownMenuSeparator className="bg-white/10" />
                    <DropdownMenuItem
                      className="gap-2 cursor-pointer hover:bg-white/5 focus:bg-white/5"
                      onClick={() => navigate('/dashboard')}
                    >
                      <LayoutDashboard className="h-4 w-4 text-gray-400" />
                      My Bookings
                    </DropdownMenuItem>
                    <DropdownMenuItem
                      className="gap-2 cursor-pointer hover:bg-white/5 focus:bg-white/5"
                      onClick={() => navigate('/my-tickets')}
                    >
                      <Ticket className="h-4 w-4 text-gray-400" />
                      Event Tickets
                    </DropdownMenuItem>
                    <DropdownMenuItem
                      className="gap-2 cursor-pointer hover:bg-white/5 focus:bg-white/5"
                      onClick={() => navigate('/profile')}
                    >
                      <User className="h-4 w-4 text-gray-400" />
                      Profile
                    </DropdownMenuItem>
                    <DropdownMenuSeparator className="bg-white/10" />
                    <DropdownMenuItem
                      className="gap-2 cursor-pointer text-red-500 hover:bg-red-500/10 focus:bg-red-500/10 focus:text-red-400"
                      onClick={handleSignOut}
                    >
                      <LogOut className="h-4 w-4" />
                      Sign Out
                    </DropdownMenuItem>
                  </DropdownMenuContent>
                </DropdownMenu>
              ) : (
                <Magnetic>
                  <Button onClick={() => setAuthOpen(true)} variant="brand">
                    Sign In
                  </Button>
                </Magnetic>
              )}
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

          {/* Scroll-read progress, under the header */}
          <span
            className="pointer-events-none absolute -bottom-px left-0 h-px bg-gradient-orange transition-[width] duration-150 ease-linear motion-reduce:hidden"
            style={{ width: `${scrollProgress}%` }}
            aria-hidden="true"
          />

          {/* Mobile Menu */}
          {isMenuOpen && (
            <div className="animate-fade-in mb-4 rounded-2xl border border-white/10 bg-black/80 p-5 backdrop-blur-2xl md:hidden">
              <nav className="flex flex-col gap-4">
                <a href="/#features" onClick={goToSection('features')} className="text-gray-300 transition-colors hover:text-orange-500">
                  Features
                </a>
                <Link to="/events" onClick={() => setIsMenuOpen(false)} className="text-gray-300 transition-colors hover:text-orange-500">
                  Events
                </Link>
                <Link to="/vip-tables" onClick={() => setIsMenuOpen(false)} className="text-gray-300 transition-colors hover:text-orange-500">
                  VIP Tables
                </Link>
                <Link to="/venues" onClick={() => setIsMenuOpen(false)} className="text-gray-300 transition-colors hover:text-orange-500">
                  Venues
                </Link>
                <a href="/#how-it-works" onClick={goToSection('how-it-works')} className="text-gray-300 transition-colors hover:text-orange-500">
                  How It Works
                </a>
                <a href="/#partners" onClick={goToSection('partners')} className="text-gray-300 transition-colors hover:text-orange-500">
                  Partners
                </a>

                {session ? (
                  <div className="flex flex-col gap-2 pt-3 border-t border-white/10">
                    <p className="text-xs text-gray-500 truncate">{profile?.name ?? session.user.email}</p>
                    <Link to="/dashboard" onClick={() => setIsMenuOpen(false)} className="flex items-center gap-2 text-gray-300 hover:text-orange-500">
                      <LayoutDashboard className="h-4 w-4" /> My Bookings
                    </Link>
                    <Link to="/my-tickets" onClick={() => setIsMenuOpen(false)} className="flex items-center gap-2 text-gray-300 hover:text-orange-500">
                      <Ticket className="h-4 w-4" /> Event Tickets
                    </Link>
                    <Link to="/profile" onClick={() => setIsMenuOpen(false)} className="flex items-center gap-2 text-gray-300 hover:text-orange-500">
                      <User className="h-4 w-4" /> Profile
                    </Link>
                    <Button
                      variant="ghost"
                      className="justify-start text-red-500 hover:bg-red-500/10 hover:text-red-400 px-0"
                      onClick={() => { setIsMenuOpen(false); handleSignOut(); }}
                    >
                      <LogOut className="mr-2 h-4 w-4" /> Sign Out
                    </Button>
                  </div>
                ) : (
                  <div className="flex flex-col gap-2 pt-3">
                    <Button variant="brandOutline">
                      Promoter Login
                    </Button>
                    <Button
                      onClick={() => window.open('https://vendor.bottlesupapp.com/', '_blank')}
                      variant="brandOutline"
                    >
                      Be Partner
                    </Button>
                    <Button
                      variant="brand"
                      onClick={() => { setIsMenuOpen(false); setAuthOpen(true); }}
                    >
                      Sign In
                    </Button>
                  </div>
                )}
              </nav>
            </div>
          )}
        </div>
      </header>

      <UserAuthModal open={authOpen} onOpenChange={setAuthOpen} />
    </>
  );
};

export default Header;
