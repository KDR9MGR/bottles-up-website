// Hand-written to match supabase/migrations/20260714120000_cms_schema.sql.
// Once the migration is applied live, prefer regenerating this file with
// `supabase gen types typescript --project-id hwmynlghrmtoufyrcihp` and diffing.

export type EventStatus = 'draft' | 'published';
export type OrderStatus = 'pending' | 'paid' | 'failed' | 'refunded';
export type PaymentsMode = 'test' | 'live';

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
          result: 'ok' | 'already_checked_in' | 'not_paid' | 'not_found';
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
