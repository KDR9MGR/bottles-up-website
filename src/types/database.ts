// Hand-written to match supabase/migrations/20260714120000_cms_schema.sql.
// Once the migration is applied live, prefer regenerating this file with
// `supabase gen types typescript --project-id hwmynlghrmtoufyrcihp` and diffing.

export type EventStatus = 'draft' | 'published';
export type OrderStatus = 'pending' | 'paid' | 'failed' | 'refunded';
export type PaymentsMode = 'test' | 'live';
export type ScanResult =
  | 'ok'
  | 'already_checked_in'
  | 'not_paid'
  | 'not_found'
  | 'expired'
  | 'code_required'
  | 'code_incorrect'
  | 'code_expired'
  | 'no_code_requested';
export type PricingMode = 'flat' | 'hourly';
export type FulfillmentStatus = 'confirmed' | 'preparing' | 'served' | 'completed';
export type DiscountType = 'percentage' | 'fixed_amount';
export type PromoAppliesTo = 'tickets' | 'tables' | 'both';

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
          venue_id: string | null;
          start_date: string;
          end_date: string | null;
          cover_image_url: string | null;
          banner_image_url: string | null;
          gallery: string[];
          category: string | null;
          status: EventStatus;
          capacity: number | null;
          show_ticket_count: boolean;
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
          is_non_transferable: boolean;
          requires_access_code: boolean;
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
          promo_code_id: string | null;
          discount_cents: number;
          ticket_code: string | null;
          ticket_sent_at: string | null;
          checked_in_at: string | null;
          checked_in_by: string | null;
          is_non_transferable: boolean;
          access_code_verified: boolean;
          access_code_verified_at: string | null;
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
      ticket_otp_codes: {
        Row: {
          id: string;
          order_id: string;
          code_hash: string;
          status: 'active' | 'verified' | 'expired';
          sent_to_email: string;
          attempts: number;
          max_attempts: number;
          created_at: string;
          expires_at: string;
          verified_at: string | null;
          verified_by: string | null;
        };
        Insert: Partial<Database['public']['Tables']['ticket_otp_codes']['Row']> & {
          order_id: string;
          code_hash: string;
          sent_to_email: string;
        };
        Update: Partial<Database['public']['Tables']['ticket_otp_codes']['Row']>;
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
          booking_start_date: string | null;
          booking_end_date: string | null;
          category: string | null;
          phone: string | null;
          website_url: string | null;
          hours_note: string | null;
          dress_code: string | null;
          capacity: number | null;
          music_genres: string | null;
          tax_rate_bps: number;
          show_bottle_images: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: Partial<Database['public']['Tables']['site_venues']['Row']> & { name: string };
        Update: Partial<Database['public']['Tables']['site_venues']['Row']>;
        Relationships: [];
      };
      site_bottles: {
        Row: {
          id: string;
          venue_id: string;
          name: string;
          size: string | null;
          description: string | null;
          price_cents: number;
          currency: string;
          category: string | null;
          image_url: string | null;
          is_available: boolean;
          is_sold_out: boolean;
          stock_quantity: number | null;
          sort_order: number;
          created_at: string;
          updated_at: string;
        };
        Insert: Partial<Database['public']['Tables']['site_bottles']['Row']> & {
          venue_id: string;
          name: string;
          price_cents: number;
        };
        Update: Partial<Database['public']['Tables']['site_bottles']['Row']>;
        Relationships: [];
      };
      site_venue_floors: {
        Row: {
          id: string;
          venue_id: string;
          label: string;
          image_url: string;
          sort_order: number;
          created_at: string;
          updated_at: string;
        };
        Insert: Partial<Database['public']['Tables']['site_venue_floors']['Row']> & {
          venue_id: string;
          label: string;
          image_url: string;
        };
        Update: Partial<Database['public']['Tables']['site_venue_floors']['Row']>;
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
          floor_id: string | null;
          pos_x: number | null;
          pos_y: number | null;
          width: number | null;
          height: number | null;
          min_guests: number | null;
          pricing_mode: PricingMode;
          hourly_rate_cents: number | null;
          min_hours: number | null;
          table_view: string | null;
          privacy_level: string | null;
          seating_type: string | null;
          amenities: string | null;
          policy_note: string | null;
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
          deposit_cents: number;
          bottle_subtotal_cents: number;
          tax_cents: number;
          bottlesup_fee_cents: number;
          promo_code_id: string | null;
          discount_cents: number;
          currency: string;
          hours: number | null;
          stripe_checkout_session_id: string | null;
          stripe_payment_intent_id: string | null;
          status: OrderStatus;
          fulfillment_status: FulfillmentStatus;
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
      site_table_booking_bottles: {
        Row: {
          id: string;
          booking_id: string;
          bottle_id: string | null;
          bottle_name: string;
          size: string | null;
          unit_price_cents: number;
          quantity: number;
          line_total_cents: number;
          created_at: string;
        };
        Insert: Partial<Database['public']['Tables']['site_table_booking_bottles']['Row']> & {
          booking_id: string;
          bottle_name: string;
          unit_price_cents: number;
          quantity: number;
          line_total_cents: number;
        };
        Update: Partial<Database['public']['Tables']['site_table_booking_bottles']['Row']>;
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
      site_vip_guests: {
        Row: {
          id: string;
          first_name: string;
          last_name: string;
          email: string;
          venue_id: string | null;
          event_id: string | null;
          created_at: string;
        };
        Insert: Partial<Database['public']['Tables']['site_vip_guests']['Row']> & {
          first_name: string;
          last_name: string;
          email: string;
        };
        Update: Partial<Database['public']['Tables']['site_vip_guests']['Row']>;
        Relationships: [];
      };
      promo_codes: {
        Row: {
          id: string;
          code: string;
          description: string | null;
          discount_type: DiscountType;
          discount_value: number;
          applies_to: PromoAppliesTo;
          max_uses: number | null;
          used_count: number;
          min_purchase_cents: number | null;
          starts_at: string | null;
          expires_at: string | null;
          is_active: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: Partial<Database['public']['Tables']['promo_codes']['Row']> & {
          code: string;
          discount_type: DiscountType;
          discount_value: number;
        };
        Update: Partial<Database['public']['Tables']['promo_codes']['Row']>;
        Relationships: [];
      };
      promo_code_venues: {
        Row: {
          promo_code_id: string;
          venue_id: string;
        };
        Insert: {
          promo_code_id: string;
          venue_id: string;
        };
        Update: Partial<{
          promo_code_id: string;
          venue_id: string;
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
          bottlesup_fee_bps: number;
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
      verify_ticket_otp: {
        Args: { p_ticket_code: string; p_code: string };
        Returns: {
          result: ScanResult;
          customer_name: string | null;
          event_title: string | null;
          tier_name: string | null;
          quantity: number | null;
          attempts_remaining: number | null;
        }[];
      };
      get_unavailable_table_types: {
        Args: { p_venue_id: string; p_booking_date: string; p_time_slot_id: string };
        Returns: string[];
      };
    };
    Enums: { [_ in never]: never };
    CompositeTypes: { [_ in never]: never };
  };
}
