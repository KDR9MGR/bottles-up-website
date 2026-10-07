// What each workspace section will hold, from the client brief (sections 4 and 5). Sections that are
// not built on the website yet say so plainly instead of showing an empty or fake screen.

const OWNER: Record<string, string> = {
  overview: 'Combined or individual venue performance; recorded sales, collections and items needing attention.',
  venues: 'Add, select and manage clubs, each with its own operational records.',
  tonight: 'Preparation checklist, live operations, alerts and closing tasks.',
  events: 'Venue requests, approved partnerships, agreements and event-specific sharing.',
  tables: 'Floor plan, reservations, guest allowances, walk-ins and table assignments.',
  'bottle-orders': 'Pre-orders, additions, signs, service estimates and delivery progress.',
  payments: 'Collections, balances, receipt evidence, cash handovers and reconciliation.',
  discounts: 'Internal codes, limits, permitted staff and usage history.',
  complimentary: 'Offers, approval, recipient location and fulfilment.',
  vip: 'Memberships, credentials, perks, preferences and assigned contacts.',
  inventory: 'Available and reserved stock, movements, discrepancies and best sellers.',
  team: 'Managers, permanent accounts, temporary access, shifts and assignments.',
  chat: 'Venue and event groups and permitted direct conversations.',
  'booking-link': 'The address guests use to book at each venue, with a QR code to print.',
  reports: 'Nightly PDFs, past performance and settlement information.',
  settings: 'Profile, booking rules, payment configuration, notifications and report recipients.',
};

const BY_ROLE: Record<string, Record<string, string>> = {
  owner: OWNER,
  manager: {
    tonight: 'Needs-attention items, live operations, and closing the night.',
    floor: 'Floor plan, reservations and table assignments for your club.',
    orders: 'Bottle orders and their delivery progress.',
    team: 'Staff, temporary access, shifts and assignments for your club.',
    more: 'Payments, discounts, inventory, reports and settings for your club.',
  },
  organizer: {
    home: 'Your events at a glance.',
    events: 'Create events, link a venue, agree terms, publish and review results.',
    guests: 'Guest lists and ticket holders for your events.',
    chat: 'Event groups and permitted direct conversations.',
    more: 'Team, settlement and settings for your events.',
  },
  server: {
    tables: 'Your assigned shift and tables.',
    orders: 'Review orders, add bottles, handle payment and evidence, mark delivered.',
    scan: 'Scan or search a booking.',
    requests: 'Service requests from your tables.',
    chat: 'Messages for your shift.',
  },
  door: {
    scan: 'Scan or search a guest, check access and confirm entry.',
    guests: 'The guest list for your assigned event.',
    'door-sale': 'Sell a ticket at the door, take payment and check the guest in.',
    chat: 'Messages for your event.',
  },
  security: {
    alerts: 'Alerts for your shift: acknowledge, respond, resolve or escalate.',
    tasks: 'Tasks assigned to you.',
    chat: 'Messages for your shift.',
    incidents: 'Report an incident, which creates a separate operational record.',
  },
  verifier: {
    review: 'The payment queue: compare each order with its evidence, then verify or flag it.',
    cash: 'Cash handovers waiting to be confirmed.',
    exceptions: 'Payments flagged for a manager to resolve.',
    summary: 'A summary of what you reviewed.',
  },
};

export function sectionDescription(role: string, section: string): string {
  return BY_ROLE[role]?.[section] ?? '';
}
