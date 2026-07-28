import { useEffect } from 'react';
import { useLocation } from 'react-router-dom';
import Header from '@/components/Header';
import Hero from '@/components/Hero';
import Features from '@/components/Features';
import PopularEvents from '@/components/PopularEvents';
import PopularVipTables from '@/components/PopularVipTables';
import HowItWorks from '@/components/HowItWorks';
import EmailCollection from '@/components/EmailCollection';
import Footer from '@/components/Footer';

const Index = () => {
  const { hash } = useLocation();

  // Handles landing here from another page via a hash link (e.g. Header/Footer
  // nav clicked from "/vip-tables"). The target section doesn't exist in the
  // DOM until this page renders, so a native browser scroll-to-hash can't find
  // it - this runs after mount instead. Sections below the fold (Events, VIP
  // Tables) render as a short "Loading..." placeholder until their Supabase
  // fetch resolves, then grow - so a single early scroll can land short of the
  // target once that data arrives. Scrolling again after a longer delay
  // corrects for that without needing a MutationObserver.
  useEffect(() => {
    if (!hash) return;
    const id = hash.slice(1);
    const scroll = () => document.getElementById(id)?.scrollIntoView({ behavior: 'smooth' });
    const timers = [setTimeout(scroll, 100), setTimeout(scroll, 800)];
    return () => timers.forEach(clearTimeout);
  }, [hash]);

  return (
    <div className="min-h-screen bg-black">
      <Header />
      <Hero />
      <Features />
      <PopularEvents />
      <PopularVipTables />
      <HowItWorks />
      <EmailCollection />
      <Footer />
    </div>
  );
};

export default Index;
