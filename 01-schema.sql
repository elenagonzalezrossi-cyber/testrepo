-- =====================================================================
-- VACATION RENTAL BOOKING ENGINE — AUTHORITATIVE SCHEMA
-- Target: Supabase (PostgreSQL 15+)
-- Jurisdiction: Portugal (Alojamento Local)
--
-- RUN THIS IN THE SUPABASE SQL EDITOR *BEFORE* CONNECTING LOVABLE.
-- Lovable must never create migrations or alter these tables.
--
-- Conventions:
--   * All money is INTEGER in cents (EUR). Never numeric, never float.
--   * All timestamps are timestamptz, stored UTC.
--   * check_in / check_out are DATE. Ranges are half-open '[)' so the
--     departure day is immediately bookable by the next guest.
-- =====================================================================

create extension if not exists btree_gist;
create extension if not exists citext;

-- ---------------------------------------------------------------------
-- ENUMS
-- ---------------------------------------------------------------------

create type booking_status  as enum ('pending','confirmed','cancelled','completed','no_show','expired');
create type booking_source  as enum ('direct','airbnb','booking_com','vrbo','manual');
create type payment_status  as enum ('unpaid','pending','paid','partially_refunded','refunded','failed');
create type block_kind      as enum ('hold','booking','owner_block');
create type block_status    as enum ('active','released','expired');
create type block_reason    as enum ('owner_use','maintenance','renovation','personal','other');
create type discount_type   as enum ('percentage','fixed');
create type property_status as enum ('draft','active','inactive');
create type app_role        as enum ('admin','staff');
create type id_document_type as enum ('passport','national_id','residence_permit','driving_licence','other');

-- ---------------------------------------------------------------------
-- ADMIN IDENTITY
-- Mirrors auth.users. Public guests never get an account.
-- ---------------------------------------------------------------------

create table profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  full_name   text,
  role        app_role not null default 'staff',
  created_at  timestamptz not null default now()
);

-- Security-definer helper so RLS policies don't recurse into profiles.
create or replace function is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and role in ('admin','staff')
  );
$$;

-- ---------------------------------------------------------------------
-- PROPERTIES
-- ---------------------------------------------------------------------

create table properties (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  slug              text not null unique,
  description       text,
  address_line1     text,
  address_line2     text,
  postal_code       text,
  city              text,
  municipality      text,              -- drives tourist tax rules
  country_code      char(2) not null default 'PT',
  latitude          numeric(9,6),
  longitude         numeric(9,6),
  timezone          text not null default 'Europe/Lisbon',
  currency          char(3) not null default 'EUR',

  max_guests        smallint not null check (max_guests > 0),
  bedrooms          smallint not null default 1,
  bathrooms         smallint not null default 1,
  base_guests       smallint not null default 2,   -- guests included before extra-guest fee
  check_in_time     time not null default '15:00',
  check_out_time    time not null default '11:00',

  -- Portugal / Alojamento Local compliance
  rnal_number       text,              -- must be displayed on the public site + emails
  complaints_book_url text,            -- Livro de Reclamações Eletrónico

  -- Default money settings (can be overridden by pricing rules)
  base_nightly_cents      integer not null default 0 check (base_nightly_cents >= 0),
  cleaning_fee_cents      integer not null default 0 check (cleaning_fee_cents >= 0),
  extra_guest_fee_cents   integer not null default 0 check (extra_guest_fee_cents >= 0),
  security_deposit_cents  integer not null default 0 check (security_deposit_cents >= 0),

  -- VAT (IVA). Portugal: 6% on accommodation; exempt below the art.53 CIVA threshold.
  vat_enabled       boolean not null default false,
  vat_rate_bps      integer not null default 600 check (vat_rate_bps between 0 and 10000),
  vat_exempt_note   text default 'IVA - regime de isenção (artigo 53.º do CIVA)',

  -- Taxa Municipal Turística. Per person, per night, capped, age-exempt.
  -- Confirm every value against your municipality's current regulamento.
  tmt_enabled             boolean not null default false,
  tmt_cents_per_person_night integer not null default 0 check (tmt_cents_per_person_night >= 0),
  tmt_max_nights          smallint,     -- null = uncapped
  tmt_min_age             smallint not null default 13,  -- guests under this are exempt
  tmt_operator_commission_bps integer not null default 0, -- e.g. 250 = 2.5% retained

  status            property_status not null default 'draft',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create table property_images (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references properties(id) on delete cascade,
  storage_path  text not null,
  alt_text      text,
  sort_order    smallint not null default 0,
  is_primary    boolean not null default false,
  created_at    timestamptz not null default now()
);
create index on property_images (property_id, sort_order);
-- At most one primary image per property.
create unique index property_images_one_primary
  on property_images (property_id) where is_primary;

create table amenities (
  id    uuid primary key default gen_random_uuid(),
  name  text not null unique,
  icon  text
);

create table property_amenities (
  property_id uuid not null references properties(id) on delete cascade,
  amenity_id  uuid not null references amenities(id)  on delete cascade,
  primary key (property_id, amenity_id)
);

-- ---------------------------------------------------------------------
-- CANCELLATION POLICIES
-- Refunds must follow the policy in force WHEN THE BOOKING WAS MADE,
-- so bookings store a frozen JSON snapshot, not just a foreign key.
-- ---------------------------------------------------------------------

create table cancellation_policies (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid references properties(id) on delete cascade, -- null = global
  code          text not null,          -- 'flexible' | 'moderate' | 'strict'
  name          text not null,
  description   text,
  -- Ordered tiers, most generous first, e.g.
  -- [{"days_before":30,"refund_bps":10000},{"days_before":7,"refund_bps":5000}]
  tiers         jsonb not null,
  refund_cleaning_fee boolean not null default true,
  refund_tourist_tax  boolean not null default true,
  is_default    boolean not null default false,
  created_at    timestamptz not null default now(),
  unique (property_id, code)
);

-- ---------------------------------------------------------------------
-- CALENDAR BLOCKS — the single source of truth for occupancy.
--
-- Holds, confirmed bookings and owner blocks are ALL rows here. One
-- exclusion constraint therefore makes double-booking impossible at the
-- database level, which no application code can achieve reliably.
--
-- Lifecycle: a hold is created -> the same row is promoted to kind
-- 'booking' when payment confirms. The dates are never momentarily free
-- between hold and booking.
-- ---------------------------------------------------------------------

create table calendar_blocks (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references properties(id) on delete cascade,
  kind        block_kind  not null,
  status      block_status not null default 'active',
  check_in    date not null,
  check_out   date not null,
  expires_at  timestamptz,             -- holds only
  stay        daterange generated always as (daterange(check_in, check_out, '[)')) stored,
  created_at  timestamptz not null default now(),

  constraint calendar_blocks_valid_range check (check_out > check_in),
  constraint calendar_blocks_hold_expiry check (
    (kind = 'hold' and expires_at is not null) or (kind <> 'hold')
  ),

  -- THE constraint. Two concurrent inserts for overlapping dates: one
  -- commits, the other raises 23P01 (exclusion_violation) -> return 409.
  constraint calendar_blocks_no_overlap exclude using gist (
    property_id with =,
    stay        with &&
  ) where (status = 'active')
);

create index on calendar_blocks (property_id, check_in, check_out) where status = 'active';
create index on calendar_blocks (expires_at) where kind = 'hold' and status = 'active';

-- Expired holds must be swept before an insert, because a constraint
-- predicate cannot reference now(). This trigger releases stale holds
-- for the property being booked; pg_cron below is the safety net.
create or replace function sweep_expired_holds()
returns trigger
language plpgsql
as $$
begin
  update calendar_blocks
     set status = 'expired'
   where property_id = new.property_id
     and kind = 'hold'
     and status = 'active'
     and expires_at < now();
  return new;
end;
$$;

create trigger calendar_blocks_sweep
  before insert on calendar_blocks
  for each row execute function sweep_expired_holds();

-- Safety net. Enable pg_cron in Supabase, then:
-- select cron.schedule('sweep-holds','* * * * *', $$
--   update calendar_blocks set status='expired'
--   where kind='hold' and status='active' and expires_at < now();
--   update booking_holds set status='expired'
--   where status='active' and expires_at < now();
-- $$);

-- ---------------------------------------------------------------------
-- GUESTS (the person who books and pays)
-- ---------------------------------------------------------------------

create table guests (
  id           uuid primary key default gen_random_uuid(),
  first_name   text not null,
  last_name    text not null,
  email        citext not null,
  phone        text,
  country_code char(2),
  notes        text,
  marketing_opt_in boolean not null default false,
  anonymised_at timestamptz,           -- GDPR erasure without breaking bookings
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index on guests (email);

-- ---------------------------------------------------------------------
-- QUOTES — authoritative server-side pricing.
-- Stripe is charged from a quote row, never from a client-supplied amount.
-- ---------------------------------------------------------------------

create table booking_quotes (
  id                uuid primary key default gen_random_uuid(),
  property_id       uuid not null references properties(id) on delete cascade,
  check_in          date not null,
  check_out         date not null,
  adults            smallint not null check (adults > 0),
  children          smallint not null default 0 check (children >= 0),
  nights            smallint not null check (nights > 0),

  nightly_subtotal_cents integer not null check (nightly_subtotal_cents >= 0),
  cleaning_fee_cents     integer not null default 0,
  extra_guest_fee_cents  integer not null default 0,
  discount_cents         integer not null default 0,
  vat_cents              integer not null default 0,
  tourist_tax_cents      integer not null default 0,
  total_cents            integer not null check (total_cents >= 0),
  currency          char(3) not null default 'EUR',

  -- Full per-night breakdown + which rules applied. Never recomputable later.
  breakdown         jsonb not null,
  expires_at        timestamptz not null,
  created_at        timestamptz not null default now(),
  constraint booking_quotes_valid_range check (check_out > check_in)
);

-- ---------------------------------------------------------------------
-- HOLDS
-- ---------------------------------------------------------------------

create table booking_holds (
  id                uuid primary key default gen_random_uuid(),
  calendar_block_id uuid not null unique references calendar_blocks(id) on delete cascade,
  property_id       uuid not null references properties(id) on delete cascade,
  quote_id          uuid references booking_quotes(id),
  session_id        text not null,
  status            text not null default 'active'
                    check (status in ('active','converted','expired','released')),
  expires_at        timestamptz not null,
  created_at        timestamptz not null default now()
);
create index on booking_holds (session_id);

-- ---------------------------------------------------------------------
-- BOOKINGS
-- ---------------------------------------------------------------------

create table bookings (
  id                uuid primary key default gen_random_uuid(),
  reference         text not null unique,   -- human-facing, e.g. 'BK-2K4M7X'
  calendar_block_id uuid unique references calendar_blocks(id) on delete set null,
  property_id       uuid not null references properties(id),
  guest_id          uuid not null references guests(id),

  check_in          date not null,
  check_out         date not null,
  nights            smallint not null check (nights > 0),
  adults            smallint not null check (adults > 0),
  children          smallint not null default 0,

  status            booking_status not null default 'pending',
  source            booking_source not null default 'direct',

  -- Money, frozen at booking time.
  nightly_subtotal_cents integer not null,
  cleaning_fee_cents     integer not null default 0,
  extra_guest_fee_cents  integer not null default 0,
  discount_cents         integer not null default 0,
  vat_cents              integer not null default 0,
  tourist_tax_cents      integer not null default 0,
  total_cents            integer not null,
  amount_paid_cents      integer not null default 0,
  amount_refunded_cents  integer not null default 0,
  currency          char(3) not null default 'EUR',
  payment_status    payment_status not null default 'unpaid',
  balance_due_at    timestamptz,            -- for future deposit + balance flow

  -- Snapshots. Do not replace with foreign keys.
  price_breakdown        jsonb not null default '{}'::jsonb,
  cancellation_policy_snapshot jsonb,

  quote_id          uuid references booking_quotes(id),
  special_requests  text,
  internal_notes    text,
  cancelled_at      timestamptz,
  cancellation_reason text,

  -- Future channel sync. Populated only for non-direct sources.
  external_id       text,
  external_status   text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint bookings_valid_range check (check_out > check_in),
  constraint bookings_paid_sane   check (amount_paid_cents >= 0 and amount_refunded_cents >= 0)
);

create index on bookings (property_id, check_in);
create index on bookings (guest_id);
create index on bookings (status);
create unique index bookings_external_unique
  on bookings (source, external_id) where external_id is not null;

-- ---------------------------------------------------------------------
-- OCCUPANTS — required for SIBA (boletim de alojamento).
-- Every non-Portuguese guest must be reported within 3 working days of
-- check-in. Collected via a pre-arrival form, not at checkout.
-- ---------------------------------------------------------------------

create table booking_occupants (
  id                uuid primary key default gen_random_uuid(),
  booking_id        uuid not null references bookings(id) on delete cascade,
  first_name        text not null,
  last_name         text not null,
  date_of_birth     date,
  nationality       char(2),
  country_of_residence char(2),
  document_type     id_document_type,
  document_number   text,
  document_issue_date  date,
  document_expiry_date date,
  is_lead_guest     boolean not null default false,
  siba_submitted_at timestamptz,
  siba_reference    text,
  created_at        timestamptz not null default now()
);
create index on booking_occupants (booking_id);

-- ---------------------------------------------------------------------
-- OWNER / MAINTENANCE BLOCKS
-- ---------------------------------------------------------------------

create table blocked_periods (
  id                uuid primary key default gen_random_uuid(),
  calendar_block_id uuid not null unique references calendar_blocks(id) on delete cascade,
  property_id       uuid not null references properties(id) on delete cascade,
  reason            block_reason not null default 'other',
  note              text,
  created_by        uuid references profiles(id),
  created_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- PRICING
-- ---------------------------------------------------------------------

create table pricing_rules (
  id             uuid primary key default gen_random_uuid(),
  property_id    uuid not null references properties(id) on delete cascade,
  name           text not null,
  start_date     date not null,
  end_date       date not null,
  nightly_cents  integer not null check (nightly_cents >= 0),
  weekend_nightly_cents integer,          -- null = same as nightly_cents
  minimum_nights smallint not null default 1 check (minimum_nights >= 1),
  priority       smallint not null default 0,  -- higher wins on overlap
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  constraint pricing_rules_valid_range check (end_date >= start_date)
);
create index on pricing_rules (property_id, start_date, end_date) where is_active;

create table discount_rules (
  id             uuid primary key default gen_random_uuid(),
  property_id    uuid not null references properties(id) on delete cascade,
  name           text not null,
  minimum_nights smallint not null check (minimum_nights > 0),
  discount_type  discount_type not null default 'percentage',
  discount_value integer not null check (discount_value >= 0), -- bps if %, cents if fixed
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- PAYMENTS
-- One booking may have many payments (deposit, balance, refunds).
-- ---------------------------------------------------------------------

create table payments (
  id                uuid primary key default gen_random_uuid(),
  booking_id        uuid references bookings(id) on delete set null,
  hold_id           uuid references booking_holds(id) on delete set null,
  provider          text not null default 'stripe',
  provider_payment_intent_id   text,
  provider_checkout_session_id text,
  provider_charge_id           text,
  amount_cents      integer not null,
  refunded_cents    integer not null default 0,
  currency          char(3) not null default 'EUR',
  status            payment_status not null default 'pending',
  failure_reason    text,
  paid_at           timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create unique index on payments (provider_checkout_session_id)
  where provider_checkout_session_id is not null;
create unique index on payments (provider_payment_intent_id)
  where provider_payment_intent_id is not null;
create index on payments (booking_id);

-- ---------------------------------------------------------------------
-- WEBHOOK IDEMPOTENCY
-- Stripe retries. Without this you will double-confirm and double-email.
-- The webhook handler MUST insert here first and abort on conflict.
-- ---------------------------------------------------------------------

create table stripe_webhook_events (
  id            text primary key,        -- Stripe's evt_... id
  type          text not null,
  payload       jsonb not null,
  processed_at  timestamptz,
  error         text,
  received_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- OUTBOUND EMAIL LOG (also idempotency)
-- ---------------------------------------------------------------------

create table notifications_log (
  id            uuid primary key default gen_random_uuid(),
  booking_id    uuid references bookings(id) on delete cascade,
  template      text not null,           -- 'booking_confirmation', etc.
  channel       text not null default 'email',
  recipient     text not null,
  provider_message_id text,
  status        text not null default 'queued',
  error         text,
  sent_at       timestamptz,
  created_at    timestamptz not null default now()
);
-- One send of each template per booking.
create unique index notifications_once
  on notifications_log (booking_id, template)
  where booking_id is not null and status in ('queued','sent');

-- ---------------------------------------------------------------------
-- AUDIT
-- ---------------------------------------------------------------------

create table audit_log (
  id          uuid primary key default gen_random_uuid(),
  actor_id    uuid references profiles(id),
  entity      text not null,
  entity_id   uuid,
  action      text not null,
  before      jsonb,
  after       jsonb,
  created_at  timestamptz not null default now()
);

-- =====================================================================
-- ROW LEVEL SECURITY
-- Default posture: everything denied. The public gets read access to
-- marketing data only. All writes go through Edge Functions using the
-- service role key, which bypasses RLS.
-- =====================================================================

alter table properties            enable row level security;
alter table property_images       enable row level security;
alter table amenities             enable row level security;
alter table property_amenities    enable row level security;
alter table cancellation_policies enable row level security;
alter table calendar_blocks       enable row level security;
alter table guests                enable row level security;
alter table booking_quotes        enable row level security;
alter table booking_holds         enable row level security;
alter table bookings              enable row level security;
alter table booking_occupants     enable row level security;
alter table blocked_periods       enable row level security;
alter table pricing_rules         enable row level security;
alter table discount_rules        enable row level security;
alter table payments              enable row level security;
alter table stripe_webhook_events enable row level security;
alter table notifications_log     enable row level security;
alter table audit_log             enable row level security;
alter table profiles              enable row level security;

-- Public read: active properties and their marketing content only.
create policy public_read_properties on properties
  for select to anon, authenticated using (status = 'active');

create policy public_read_images on property_images
  for select to anon, authenticated using (
    exists (select 1 from properties p where p.id = property_id and p.status = 'active')
  );

create policy public_read_amenities on amenities
  for select to anon, authenticated using (true);

create policy public_read_property_amenities on property_amenities
  for select to anon, authenticated using (true);

create policy public_read_policies on cancellation_policies
  for select to anon, authenticated using (true);

create policy public_read_pricing on pricing_rules
  for select to anon, authenticated using (is_active);

create policy public_read_discounts on discount_rules
  for select to anon, authenticated using (is_active);

-- Availability: dates only. No guest names, no reasons, no amounts.
-- Expose through this view, never the base table.
create view public_availability
with (security_invoker = off) as
  select property_id, check_in, check_out
    from calendar_blocks
   where status = 'active';

grant select on public_availability to anon, authenticated;

-- Admins read and write everything.
create policy admin_all_properties       on properties            for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all_images           on property_images       for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all_amenities        on amenities             for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all_prop_amenities   on property_amenities    for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all_policies         on cancellation_policies for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all_blocks           on calendar_blocks       for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all_guests           on guests                for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all_quotes           on booking_quotes        for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all_holds            on booking_holds         for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all_bookings         on bookings              for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all_occupants        on booking_occupants     for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all_blocked          on blocked_periods       for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all_pricing          on pricing_rules         for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all_discounts        on discount_rules        for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all_payments         on payments              for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all_notifications    on notifications_log     for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_read_audit           on audit_log             for select to authenticated using (is_admin());
create policy admin_read_profiles        on profiles              for select to authenticated using (is_admin());

-- stripe_webhook_events: no policies at all. Service role only.

-- ---------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------

create or replace function touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end; $$;

create trigger t_properties_touch before update on properties
  for each row execute function touch_updated_at();
create trigger t_bookings_touch   before update on bookings
  for each row execute function touch_updated_at();
create trigger t_guests_touch     before update on guests
  for each row execute function touch_updated_at();
create trigger t_payments_touch   before update on payments
  for each row execute function touch_updated_at();
