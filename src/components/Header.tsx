import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { Menu, X } from 'lucide-react';

const Header = () => {
  const [isMenuOpen, setIsMenuOpen] = useState(false);

  return (
    <header className="fixed top-0 left-0 right-0 z-50 bg-black/95 backdrop-blur-sm border-b border-gray-800">
      <div className="container mx-auto px-4 lg:px-6">
        <div className="flex items-center justify-between h-16">
          {/* Logo */}
          <Link to="/" className="flex items-center space-x-3">
            <img
              src="/app_logo.svg"
              alt="BottlesUp Logo"
              className="w-8 h-8"
            />
            <span className="text-xl font-bold text-gradient">BottlesUp</span>
          </Link>

          {/* Desktop Navigation */}
          <nav className="hidden md:flex items-center space-x-8">
            <a href="#features" className="text-gray-300 hover:text-orange-500 transition-colors">
              Features
            </a>
            <a href="#events" className="text-gray-300 hover:text-orange-500 transition-colors">
              Events
            </a>
            <a href="#booking" className="text-gray-300 hover:text-orange-500 transition-colors">
              VIP Tables
            </a>
            <a href="#partners" className="text-gray-300 hover:text-orange-500 transition-colors">
              Partners
            </a>
          </nav>

          {/* Desktop CTA */}
          <div className="hidden md:flex items-center space-x-4">
            <Button variant="outline" className="border-orange-500 text-orange-500 hover:bg-orange-500 hover:text-black">
              Promoter Login
            </Button>
            <Button 
              onClick={() => window.open('https://vendor.bottlesupapp.com/', '_blank')}
              className="bg-gradient-orange hover:opacity-90 text-black font-bold border-0"
            >
              Be Partner
            </Button>
            <Button className="bg-gradient-orange hover:opacity-90 text-black font-bold border-0">
              Join Waitlist
            </Button>
          </div>

          {/* Mobile Menu Button */}
          <button
            className="md:hidden text-white"
            onClick={() => setIsMenuOpen(!isMenuOpen)}
          >
            {isMenuOpen ? <X className="w-6 h-6" /> : <Menu className="w-6 h-6" />}
          </button>
        </div>

        {/* Mobile Menu */}
        {isMenuOpen && (
          <div className="md:hidden py-4 border-t border-gray-800 animate-fade-in">
            <nav className="flex flex-col space-y-4">
              <a href="#features" className="text-gray-300 hover:text-orange-500 transition-colors">
                Features
              </a>
              <a href="#events" className="text-gray-300 hover:text-orange-500 transition-colors">
                Events
              </a>
              <a href="#booking" className="text-gray-300 hover:text-orange-500 transition-colors">
                VIP Tables
              </a>
              <a href="#partners" className="text-gray-300 hover:text-orange-500 transition-colors">
                Partners
              </a>
              <div className="flex flex-col space-y-2 pt-4">
                <Button variant="outline" className="border-orange-500 text-orange-500 hover:bg-orange-500 hover:text-black">
                  Promoter Login
                </Button>
                <Button 
                  onClick={() => window.open('https://vendor.bottlesupapp.com/', '_blank')}
                  className="bg-gradient-orange hover:opacity-90 text-black font-bold border-0"
                >
                  Be Partner
                </Button>
                <Button className="bg-gradient-orange hover:opacity-90 text-black font-bold border-0">
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
