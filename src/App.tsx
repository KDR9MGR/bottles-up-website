import { Toaster } from "@/components/ui/toaster";
import { Toaster as Sonner } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BrowserRouter, Routes, Route } from "react-router-dom";
import Index from "./pages/Index";
import PrivacyPolicy from "./pages/PrivacyPolicy";
import NotFound from "./pages/NotFound";
import ScrollToTop from "./components/ScrollToTop";
import RequireCmsAuth from "./cms/RequireCmsAuth";
import CmsLayout from "./cms/CmsLayout";
import CmsLogin from "./cms/pages/Login";
import CmsDashboard from "./cms/pages/Dashboard";
import CmsEvents from "./cms/pages/Events";
import CmsBookings from "./cms/pages/Bookings";
import CmsVenues from "./cms/pages/Venues";
import CmsTableBookings from "./cms/pages/TableBookings";
import CmsVipList from "./cms/pages/VipList";
import CmsVipGuestList from "./cms/pages/VipGuestList";
import CmsDoorStaff from "./cms/pages/DoorStaff";
import CmsCheckIns from "./cms/pages/CheckIns";
import CmsAuditLog from "./cms/pages/AuditLog";
import CmsContent from "./cms/pages/Content";
import CmsHelp from "./cms/pages/Help";
import BookingSuccess from "./pages/BookingSuccess";
import BookingCancel from "./pages/BookingCancel";
import EventDetail from "./pages/EventDetail";
import Events from "./pages/Events";
import VipTables from "./pages/VipTables";
import Venues from "./pages/Venues";
import VenueDetail from "./pages/VenueDetail";
import TableDetail from "./pages/TableDetail";
import MyTickets from "./pages/MyTickets";
import UserDashboard from "./pages/UserDashboard";
import UserProfile from "./pages/UserProfile";
import UserBookingDetail from "./pages/UserBookingDetail";
import RequireDoorAuth from "./door/RequireDoorAuth";
import DoorLogin from "./door/pages/DoorLogin";
import ScanTickets from "./door/pages/ScanTickets";

const queryClient = new QueryClient();

const App = () => {
  return (
    <QueryClientProvider client={queryClient}>
      <TooltipProvider>
        <Toaster />
        <Sonner />
        <BrowserRouter>
          <ScrollToTop />
          <Routes>
            <Route path="/" element={<Index />} />
            <Route path="/privacy-policy" element={<PrivacyPolicy />} />
            <Route path="/events" element={<Events />} />
            <Route path="/events/:id" element={<EventDetail />} />
            <Route path="/vip-tables" element={<VipTables />} />
            <Route path="/venues" element={<Venues />} />
            <Route path="/venues/:id" element={<VenueDetail />} />
            <Route path="/tables/:id" element={<TableDetail />} />
            <Route path="/booking/success" element={<BookingSuccess />} />
            <Route path="/booking/cancel" element={<BookingCancel />} />
            <Route path="/my-tickets" element={<MyTickets />} />
            <Route path="/dashboard" element={<UserDashboard />} />
            <Route path="/profile" element={<UserProfile />} />
            <Route path="/bookings/:type/:id" element={<UserBookingDetail />} />
            <Route path="/door/login" element={<DoorLogin />} />
            <Route
              path="/door/scan"
              element={
                <RequireDoorAuth>
                  <ScanTickets />
                </RequireDoorAuth>
              }
            />
            <Route path="/cms/login" element={<CmsLogin />} />
            <Route
              path="/cms/*"
              element={
                <RequireCmsAuth>
                  <CmsLayout />
                </RequireCmsAuth>
              }
            >
              <Route index element={<CmsDashboard />} />
              <Route path="events" element={<CmsEvents />} />
              <Route path="bookings" element={<CmsBookings />} />
              <Route path="venues" element={<CmsVenues />} />
              <Route path="table-bookings" element={<CmsTableBookings />} />
              <Route path="vip-list" element={<CmsVipList />} />
              <Route path="vip-guest-list" element={<CmsVipGuestList />} />
              <Route path="door-staff" element={<CmsDoorStaff />} />
              <Route path="check-ins" element={<CmsCheckIns />} />
              <Route path="audit-log" element={<CmsAuditLog />} />
              <Route path="content" element={<CmsContent />} />
              <Route path="help" element={<CmsHelp />} />
            </Route>
            {/* ADD ALL CUSTOM ROUTES ABOVE THE CATCH-ALL "*" ROUTE */}
            <Route path="*" element={<NotFound />} />
          </Routes>
        </BrowserRouter>
      </TooltipProvider>
    </QueryClientProvider>
  );
};

export default App;
