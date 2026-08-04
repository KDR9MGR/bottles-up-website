import { NavLink, Outlet } from 'react-router-dom';
import { LayoutDashboard, CalendarDays, Ticket, Users, Settings, LogOut, ScanLine, CheckCircle2, ScrollText, Building2, Wine, HelpCircle } from 'lucide-react';
import {
  Sidebar,
  SidebarContent,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarInset,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarTrigger,
} from '@/components/ui/sidebar';
import { cmsSignOut } from './useCmsAuth';

const navItems = [
  { to: '/cms', label: 'Dashboard', icon: LayoutDashboard, end: true },
  { to: '/cms/events', label: 'Events', icon: CalendarDays },
  { to: '/cms/bookings', label: 'Bookings', icon: Ticket },
  { to: '/cms/venues', label: 'Venues', icon: Building2 },
  { to: '/cms/table-bookings', label: 'Table Bookings', icon: Wine },
  { to: '/cms/vip-list', label: 'VIP List', icon: Users },
  { to: '/cms/door-staff', label: 'Door Staff', icon: ScanLine },
  { to: '/cms/check-ins', label: 'Check-ins', icon: CheckCircle2 },
  { to: '/cms/audit-log', label: 'Audit Log', icon: ScrollText },
  { to: '/cms/content', label: 'Site Content', icon: Settings },
  { to: '/cms/help', label: 'Help & Guides', icon: HelpCircle },
];

const CmsLayout = () => {
  return (
    <SidebarProvider>
      <div className="flex min-h-screen w-full bg-black text-white">
        <Sidebar>
          <SidebarHeader className="px-4 py-4">
            <span className="text-lg font-bold text-gradient">BottlesUp CMS</span>
          </SidebarHeader>
          <SidebarContent>
            <SidebarGroup>
              <SidebarGroupLabel>Manage</SidebarGroupLabel>
              <SidebarGroupContent>
                <SidebarMenu>
                  {navItems.map((item) => (
                    <SidebarMenuItem key={item.to}>
                      <SidebarMenuButton asChild>
                        <NavLink
                          to={item.to}
                          end={item.end}
                          className={({ isActive }) =>
                            isActive ? 'text-orange-500' : undefined
                          }
                        >
                          <item.icon />
                          <span>{item.label}</span>
                        </NavLink>
                      </SidebarMenuButton>
                    </SidebarMenuItem>
                  ))}
                  <SidebarMenuItem>
                    <SidebarMenuButton onClick={() => cmsSignOut()}>
                      <LogOut />
                      <span>Sign out</span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                </SidebarMenu>
              </SidebarGroupContent>
            </SidebarGroup>
          </SidebarContent>
        </Sidebar>
        <SidebarInset className="bg-black">
          <header className="flex h-14 items-center border-b border-gray-800 px-4">
            <SidebarTrigger />
          </header>
          <main className="flex-1 p-6">
            <Outlet />
          </main>
        </SidebarInset>
      </div>
    </SidebarProvider>
  );
};

export default CmsLayout;
