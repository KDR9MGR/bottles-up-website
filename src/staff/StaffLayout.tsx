import { NavLink, Outlet } from 'react-router-dom';
import { Wine, ClipboardList, Bell, User } from 'lucide-react';

const navItems = [
  { to: '/staff/tables', label: 'My Tables', icon: Wine, end: true },
  { to: '/staff/orders', label: 'Bottle Orders', icon: ClipboardList },
  { to: '/staff/alerts', label: 'Alerts', icon: Bell },
  { to: '/staff/profile', label: 'Profile', icon: User },
];

// BottlesUp Server and Pay-at-Club system, section 2: "After signing in,
// servers should only see: My Tables, Bottle Orders, Alerts, Profile."
// Bottom-tab nav, mobile-first like every other /door screen - staff use
// this on a phone at the venue, not a desktop.
const StaffLayout = () => {
  return (
    <div className="flex min-h-screen flex-col bg-black text-white">
      <main className="flex-1 pb-20">
        <Outlet />
      </main>
      <nav className="fixed bottom-0 left-0 right-0 flex border-t border-gray-800 bg-gray-950">
        {navItems.map((item) => (
          <NavLink
            key={item.to}
            to={item.to}
            end={item.end}
            className={({ isActive }) =>
              `flex flex-1 flex-col items-center gap-1 py-2.5 text-xs ${isActive ? 'text-orange-500' : 'text-gray-500'}`
            }
          >
            <item.icon className="h-5 w-5" />
            {item.label}
          </NavLink>
        ))}
      </nav>
    </div>
  );
};

export default StaffLayout;
