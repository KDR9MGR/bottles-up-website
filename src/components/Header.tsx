import { useState } from 'react';
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

const navLinkClass =
  'relative text-sm font-medium text-gray-300 transition-colors hover:text-white after:absolute after:-bottom-1 after:left-0 after:h-px after:w-0 after:bg-gradient-orange after:transition-all after:duration-300 hover:after:w-full';

const Header = () => {
  const [isMenuOpen, setIsMenuOpen] = useState(false);
  const [authOpen, setAuthOpen] = useState(false);
  const location = useLocation();
  const navigate = useNavigate();
  const { session, profile } = useUserAuth();

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
                variant="outline"
                className="rounded-full border-orange-500/60 text-orange-500 transition-all duration-300 hover:border-orange-500 hover:bg-orange-500/10 hover:text-orange-400"
              >
                Be Partner
              </Button>

              {/* User auth */}
              {session ? (
                <DropdownMenu>
                  <DropdownMenuTrigger asChild>
                    <button className="h-9 w-9 rounded-full bg-gradient-to-br from-orange-500 to-orange-600 text-black text-sm font-bold flex items-center justify-center hover:opacity-90 transition-opacity">
                      {initials}
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
                <Button
                  onClick={() => setAuthOpen(true)}
                  className="rounded-full bg-gradient-orange border-0 font-bold text-black shadow-lg shadow-orange-500/20 transition-all duration-300 hover:scale-105 hover:shadow-orange-500/40"
                >
                  Sign In
                </Button>
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
                    <Button
                      className="rounded-full bg-gradient-orange border-0 font-bold text-black"
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
