import { Toaster } from "@/components/ui/toaster";
import { Toaster as Sonner } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Suspense, lazy, type ReactNode } from "react";
import { BrowserRouter, Routes, Route } from "react-router-dom";
import Spotlight from "@/components/motion/Spotlight";
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
import CmsReconciliation from "./cms/pages/Reconciliation";
import CmsPromoCodes from "./cms/pages/PromoCodes";
import CmsVipList from "./cms/pages/VipList";
import CmsVipGuestList from "./cms/pages/VipGuestList";
import CmsDoorStaff from "./cms/pages/DoorStaff";
import CmsCheckIns from "./cms/pages/CheckIns";
import CmsAuditLog from "./cms/pages/AuditLog";
import CmsContent from "./cms/pages/Content";
import CmsHelp from "./cms/pages/Help";
import BookingSuccess from "./pages/BookingSuccess";
import BookingCancel from "./pages/BookingCancel";
import ClubPaymentConfirm from "./pages/ClubPaymentConfirm";
import OrderByCode from "./pages/OrderByCode";
import BookingByCode from "./pages/BookingByCode";
import BottleSubstitutionConfirm from "./pages/BottleSubstitutionConfirm";
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
import CheckInTables from "./door/pages/CheckInTables";
import StaffLayout from "./staff/StaffLayout";
import MyTables from "./staff/pages/MyTables";
import BottleOrders from "./staff/pages/BottleOrders";
import Alerts from "./staff/pages/Alerts";
import Profile from "./staff/pages/Profile";
import StaffTableDetail from "./staff/pages/StaffTableDetail";
import PartnerApply from "./partners/pages/PartnerApply";
import PartnerLogin from "./partners/pages/PartnerLogin";
import PartnerOnboarding from "./partners/pages/PartnerOnboarding";
import { AccountProvider } from "./hooks/AccountProvider";
import { ACCOUNT_ONBOARDING_ENABLED } from "./lib/features";

// New account, onboarding and workspace pages. Loaded on demand, and only routed when the feature is on
// (see lib/features.ts), so the live site does not even download them until it is switched on.
const Login = lazy(() => import("./account/pages/Login"));
const Signup = lazy(() => import("./account/pages/Signup"));
const SignupPersonal = lazy(() => import("./account/pages/SignupPersonal"));
const SignupBusiness = lazy(() => import("./account/pages/SignupBusiness"));
const AccountHome = lazy(() => import("./account/pages/Home"));
const WorkspacesPage = lazy(() => import("./account/pages/WorkspacesPage"));
const ProfileOnboarding = lazy(() => import("./account/pages/ProfileOnboarding"));
const BusinessNew = lazy(() => import("./account/pages/BusinessNew"));
const BusinessOnboarding = lazy(() => import("./account/pages/BusinessOnboarding"));
const AcceptInvite = lazy(() => import("./account/pages/AcceptInvite"));
const WorkspacePage = lazy(() => import("./account/workspace/WorkspacePage"));
const CmsVerifications = lazy(() => import("./cms/pages/Verifications"));

const AccountScope = ({ children }: { children: ReactNode }) =>
  ACCOUNT_ONBOARDING_ENABLED ? <AccountProvider>{children}</AccountProvider> : <>{children}</>;

const Fallback = () => (
  <div className="flex min-h-screen items-center justify-center bg-black text-gray-400">Loading...</div>
);

const queryClient = new QueryClient();

const App = () => {
  return (
    <QueryClientProvider client={queryClient}>
      <TooltipProvider>
        <Toaster />
        <Sonner />
        <Spotlight />
        <BrowserRouter>
          <AccountScope>
          <ScrollToTop />
          <Suspense fallback={<Fallback />}>
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
            <Route path="/club-payment/confirm/:token" element={<ClubPaymentConfirm />} />
            <Route path="/bottle-substitution/confirm/:token" element={<BottleSubstitutionConfirm />} />
            <Route path="/order/:code" element={<OrderByCode />} />
            <Route path="/booking/:code" element={<BookingByCode />} />
            <Route path="/my-tickets" element={<MyTickets />} />
            <Route path="/dashboard" element={<UserDashboard />} />
            <Route path="/profile" element={<UserProfile />} />
            <Route path="/bookings/:type/:id" element={<UserBookingDetail />} />
            <Route path="/partners/apply" element={<PartnerApply />} />
            <Route path="/partners/login" element={<PartnerLogin />} />
            <Route path="/partners/onboarding" element={<PartnerOnboarding />} />
            <Route path="/door/login" element={<DoorLogin />} />
            <Route path="/staff/login" element={<DoorLogin />} />
            <Route
              path="/door/scan"
              element={
                <RequireDoorAuth>
                  <ScanTickets />
                </RequireDoorAuth>
              }
            />
            <Route
              path="/door/tables"
              element={
                <RequireDoorAuth>
                  <CheckInTables />
                </RequireDoorAuth>
              }
            />
            <Route
              path="/staff/*"
              element={
                <RequireDoorAuth>
                  <StaffLayout />
                </RequireDoorAuth>
              }
            >
              <Route path="tables" element={<MyTables />} />
              <Route path="tables/:code" element={<StaffTableDetail />} />
              <Route path="orders" element={<BottleOrders />} />
              <Route path="alerts" element={<Alerts />} />
              <Route path="profile" element={<Profile />} />
            </Route>
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
              <Route path="reconciliation" element={<CmsReconciliation />} />
              <Route path="promo-codes" element={<CmsPromoCodes />} />
              {ACCOUNT_ONBOARDING_ENABLED && <Route path="verifications" element={<CmsVerifications />} />}
              <Route path="vip-list" element={<CmsVipList />} />
              <Route path="vip-guest-list" element={<CmsVipGuestList />} />
              <Route path="door-staff" element={<CmsDoorStaff />} />
              <Route path="check-ins" element={<CmsCheckIns />} />
              <Route path="audit-log" element={<CmsAuditLog />} />
              <Route path="content" element={<CmsContent />} />
              <Route path="help" element={<CmsHelp />} />
            </Route>
            {ACCOUNT_ONBOARDING_ENABLED && (
              <>
                <Route path="/login" element={<Login />} />
                <Route path="/signup" element={<Signup />} />
                <Route path="/signup/personal" element={<SignupPersonal />} />
                <Route path="/signup/business" element={<SignupBusiness />} />
                <Route path="/home" element={<AccountHome />} />
                <Route path="/workspaces" element={<WorkspacesPage />} />
                <Route path="/onboarding/profile" element={<ProfileOnboarding />} />
                <Route path="/business/new" element={<BusinessNew />} />
                <Route path="/business/:orgId/onboarding" element={<BusinessOnboarding />} />
                <Route path="/accept-invite" element={<AcceptInvite />} />
                <Route path="/w/:membershipId" element={<WorkspacePage />} />
                <Route path="/w/:membershipId/:section" element={<WorkspacePage />} />
              </>
            )}
            {/* ADD ALL CUSTOM ROUTES ABOVE THE CATCH-ALL "*" ROUTE */}
            <Route path="*" element={<NotFound />} />
          </Routes>
          </Suspense>
          </AccountScope>
        </BrowserRouter>
      </TooltipProvider>
    </QueryClientProvider>
  );
};

export default App;
