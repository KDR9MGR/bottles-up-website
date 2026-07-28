// Hand-written to match supabase/migrations/20260714120000_cms_schema.sql.
// Once the migration is applied live, prefer regenerating this file with
// `supabase gen types typescript --project-id hwmynlghrmtoufyrcihp` and diffing.

export type EventStatus = 'draft' | 'published';
export type OrderStatus = 'pending' | 'paid' | 'failed' | 'refunded';
export type PaymentsMode = 'test' | 'live';
export type ScanResult = 'ok' | 'already_checked_in' | 'not_paid' | 'not_found' | 'expired';

export interface Database {
  public: {
    Tables: {
      cms_admins: {
        Row: {
          id: string;
          email: string;
          created_at: string;
        };
        Insert: {
          id: string;
          email: string;
          created_at?: string;
        };
        Update: Partial<{
          id: string;
          email: string;
          created_at: string;
        }>;
        Relationships: [];
      };
      site_events: {
        Row: {
          id: string;
          title: string;
          slug: string | null;
          description: string;
          venue_name: string;
          address: string | null;
          start_date: string;
          end_date: string | null;
          cover_image_url: string | null;
          banner_image_url: string | null;
          gallery: string[];
          category: string | null;
          status: EventStatus;
          capacity: number | null;
          created_at: string;
          updated_at: string;
        };
        Insert: Partial<Database['public']['Tables']['site_events']['Row']> & {
          title: string;
          description: string;
          venue_name: string;
          start_date: string;
        };
        Update: Partial<Database['public']['Tables']['site_events']['Row']>;
        Relationships: [];
      };
      site_ticket_tiers: {
        Row: {
          id: string;
          event_id: string;
          name: string;
          price_cents: number;
          currency: string;
          capacity: number;
          sold_count: number;
          created_at: string;
          updated_at: string;
        };
        Insert: Partial<Database['public']['Tables']['site_ticket_tiers']['Row']> & {
          event_id: string;
          name: string;
          price_cents: number;
          capacity: number;
        };
        Update: Partial<Database['public']['Tables']['site_ticket_tiers']['Row']>;
        Relationships: [];
      };
      site_orders: {
        Row: {
          id: string;
          event_id: string;
          tier_id: string;
          customer_name: string;
          customer_email: string;
          customer_phone: string | null;
          quantity: number;
          amount_total_cents: number;
          currency: string;
          stripe_checkout_session_id: string | null;
          stripe_payment_intent_id: string | null;
          status: OrderStatus;
          ticket_code: string | null;
          ticket_sent_at: string | null;
          checked_in_at: string | null;
          checked_in_by: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: Partial<Database['public']['Tables']['site_orders']['Row']> & {
          event_id: string;
          tier_id: string;
          customer_name: string;
          customer_email: string;
          quantity: number;
          amount_total_cents: number;
        };
        Update: Partial<Database['public']['Tables']['site_orders']['Row']>;
        Relationships: [];
      };
      vip_emails: {
        Row: {
          id: string;
          email: string;
          first_name: string | null;
          last_name: string | null;
          source: string;
          mailchimp_synced: boolean;
          created_at: string;
        };
        Insert: Partial<Database['public']['Tables']['vip_emails']['Row']> & {
          email: string;
        };
        Update: Partial<Database['public']['Tables']['vip_emails']['Row']>;
        Relationships: [];
      };
      door_staff: {
        Row: {
          id: string;
          email: string;
          created_at: string;
        };
        Insert: {
          id: string;
          email: string;
          created_at?: string;
        };
        Update: Partial<{
          id: string;
          email: string;
          created_at: string;
        }>;
        Relationships: [];
      };
      scan_attempts: {
        Row: {
          id: string;
          ticket_code_attempted: string;
          result: ScanResult;
          order_id: string | null;
          booking_id: string | null;
          scanned_by: string;
          created_at: string;
        };
        Insert: {
          id?: string;
          ticket_code_attempted: string;
          result: ScanResult;
          order_id?: string | null;
          booking_id?: string | null;
          scanned_by: string;
          created_at?: string;
        };
        Update: Partial<Database['public']['Tables']['scan_attempts']['Row']>;
        Relationships: [];
      };
      site_venues: {
        Row: {
          id: string;
          name: string;
          slug: string | null;
          description: string | null;
          address: string | null;
          cover_image_url: string | null;
          gallery: string[];
          status: EventStatus;
          created_at: string;
          updated_at: string;
        };
        Insert: Partial<Database['public']['Tables']['site_venues']['Row']> & { name: string };
        Update: Partial<Database['public']['Tables']['site_venues']['Row']>;
        Relationships: [];
      };
      site_venue_time_slots: {
        Row: {
          id: string;
          venue_id: string;
          day_of_week: number;
          start_time: string;
          label: string | null;
          created_at: string;
        };
        Insert: Partial<Database['public']['Tables']['site_venue_time_slots']['Row']> & {
          venue_id: string;
          day_of_week: number;
          start_time: string;
        };
        Update: Partial<Database['public']['Tables']['site_venue_time_slots']['Row']>;
        Relationships: [];
      };
      site_table_types: {
        Row: {
          id: string;
          venue_id: string;
          name: string;
          description: string | null;
          max_guests: number;
          min_spend_cents: number;
          deposit_cents: number;
          currency: string;
          inventory_count: number;
          image_url: string | null;
          badge_label: string | null;
          is_featured: boolean;
          sort_order: number;
          created_at: string;
          updated_at: string;
        };
        Insert: Partial<Database['public']['Tables']['site_table_types']['Row']> & {
          venue_id: string;
          name: string;
          max_guests: number;
          min_spend_cents: number;
          deposit_cents: number;
          inventory_count: number;
        };
        Update: Partial<Database['public']['Tables']['site_table_types']['Row']>;
        Relationships: [];
      };
      site_table_bookings: {
        Row: {
          id: string;
          venue_id: string;
          table_type_id: string;
          time_slot_id: string;
          booking_date: string;
          customer_name: string;
          customer_email: string;
          customer_phone: string | null;
          guest_count: number;
          amount_total_cents: number;
          currency: string;
          stripe_checkout_session_id: string | null;
          stripe_payment_intent_id: string | null;
          status: OrderStatus;
          confirmation_code: string | null;
          confirmation_sent_at: string | null;
          checked_in_at: string | null;
          checked_in_by: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: Partial<Database['public']['Tables']['site_table_bookings']['Row']> & {
          venue_id: string;
          table_type_id: string;
          time_slot_id: string;
          booking_date: string;
          customer_name: string;
          customer_email: string;
          guest_count: number;
          amount_total_cents: number;
        };
        Update: Partial<Database['public']['Tables']['site_table_bookings']['Row']>;
        Relationships: [];
      };
      audit_log: {
        Row: {
          id: string;
          actor_id: string | null;
          actor_email: string;
          action: string;
          entity_type: string;
          entity_id: string | null;
          details: Record<string, unknown> | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          actor_id?: string | null;
          actor_email: string;
          action: string;
          entity_type: string;
          entity_id?: string | null;
          details?: Record<string, unknown> | null;
          created_at?: string;
        };
        Update: Partial<Database['public']['Tables']['audit_log']['Row']>;
        Relationships: [];
      };
      site_content: {
        Row: {
          id: number;
          contact_email: string | null;
          contact_phone: string | null;
          address: string | null;
          social_instagram: string | null;
          social_twitter: string | null;
          social_facebook: string | null;
          social_linkedin: string | null;
          footer_tagline: string | null;
          hero_headline: string | null;
          hero_subtext: string | null;
          payments_mode: PaymentsMode;
          updated_at: string;
        };
        Insert: Partial<Database['public']['Tables']['site_content']['Row']>;
        Update: Partial<Database['public']['Tables']['site_content']['Row']>;
        Relationships: [];
      };
    };
    Views: { [_ in never]: never };
    Functions: {
      checkin_ticket: {
        Args: { p_ticket_code: string };
        Returns: {
          result: ScanResult;
          customer_name: string | null;
          event_title: string | null;
          tier_name: string | null;
          quantity: number | null;
        }[];
      };
    };
    Enums: { [_ in never]: never };
    CompositeTypes: { [_ in never]: never };
  };
}
