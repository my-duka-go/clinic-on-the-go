-- Clinic On the Go - complete database for the clinic's own Supabase project (hugaqzeqefzzpsvaanfm).
-- Part 1: the POS foundation, copied from the live My DukaGO POS database (20 Oct 2026) so the sign-in functions,
-- row-level security and sync work the same. Part 2 (clinic_tables_and_security.sql): patients, visits, appointments, dispensing.
-- Safe to run again: anything that already exists is skipped.
-- A "shop" here is a clinic; table and column names stay as in the POS so the shared code keeps working.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_cron;

-- ---------- helpers used by defaults and policies ----------
create or replace function public.jwt_shop_id() returns uuid language sql stable set search_path to 'public' as $$
  select nullif(auth.jwt() -> 'app_metadata' ->> 'shop_id', '')::uuid
$$;
create or replace function public.jwt_role() returns text language sql stable set search_path to 'public' as $$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '')
$$;

-- ---------- tables ----------
create table if not exists public.shops (id uuid not null default gen_random_uuid(), name text, created_at timestamptz default now(), active boolean default true, license_status text not null default 'active', license_note text, plan text not null default 'small', license_expires_at timestamptz, shop_code text not null, license_cycle text default 'monthly');
create or replace function public.gen_shop_code() returns text language plpgsql set search_path to 'public' as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  c text; i int;
begin
  loop
    c := '';
    for i in 1..5 loop
      c := c || substr(alphabet, 1 + floor(random()*length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.shops where shop_code = c);
  end loop;
  return c;
end $$;
alter table public.shops alter column shop_code set default public.gen_shop_code();

create table if not exists public.audit_log (id text not null, shop_id uuid not null, ts timestamptz not null default now(), actor text, role text, action text, details text);
create table if not exists public.cart_removal_requests (id text not null, shop_id uuid, kind text, item_info jsonb, reason text, requested_by text, requested_at timestamptz default now(), status text default 'pending', reviewed_by text, reviewed_at timestamptz, review_note text);
create table if not exists public.customer_debts (id text not null, shop_id uuid, customer_name text, customer_phone text, amount numeric, date_given date, notes text, status text default 'owing', paid_date date, added_by text, updated_at timestamptz default now(), cost numeric, due_date date, line_items jsonb, tax numeric default 0,
  kind text, claim jsonb);                                   -- clinic: kind = 'claim' for an insurance claim, with its details
create table if not exists public.license_payment_requests (id uuid not null default gen_random_uuid(), shop_id text not null, shop_name text, shop_code text, mpesa_code text not null, amount numeric not null, months integer not null default 1, plan text, requested_by text, requested_at timestamptz not null default now(), status text not null default 'pending', decided_by text, decided_at timestamptz, decision_note text, extends_to timestamptz, cycle text not null default 'monthly');
create table if not exists public.mpesa_c2b_payments (id bigint generated always as identity, trans_id text, trans_time text, trans_amount numeric, business_short_code text, bill_ref_number text, msisdn text, first_name text, matched boolean default false, matched_sale_id text, created_at timestamptz default now());
create table if not exists public.mpesa_requests (checkout_request_id text not null, merchant_request_id text, shop_id uuid, phone text, amount numeric, status text default 'pending', mpesa_receipt text, result_desc text, created_at timestamptz default now(), updated_at timestamptz default now());
create table if not exists public.payables (id text not null, shop_id uuid, supplier_name text, amount numeric, invoice_date date, due_date date, photo text, notes text, status text default 'unpaid', added_by text, paid_date date, paid_by text, updated_at timestamptz default now(), stock_update_status text, stock_update_by text, stock_update_at timestamptz, po_number text);
create table if not exists public.pin_reset_config (k text not null, v text not null);
create table if not exists public.pin_resets (id uuid not null default gen_random_uuid(), shop_id uuid not null, email text not null, code_hash text not null, attempts integer not null default 0, expires_at timestamptz not null, used_at timestamptz, created_at timestamptz not null default now());
create table if not exists public.platform_admins (id text not null, name text, pin text, email text, phone text, active boolean default true, created_at timestamptz default now());
create table if not exists public.platform_audit_log (id bigint generated always as identity, admin_name text, action text, details text, shop_id uuid, ts timestamptz default now());
create table if not exists public.platform_business_types (id text not null, label text, emoji text, description text, cats jsonb, colors jsonb, created_by text, created_at timestamptz default now());
create table if not exists public.po_number_counters (shop_id uuid not null, last_number integer not null default 0);
create table if not exists public.product_tombstones (shop_id uuid not null, sku text not null, deleted_at timestamptz not null default now());
create table if not exists public.products (sku text not null, shop_id uuid not null, name text, cat text, price numeric, cost numeric, stock numeric, btype text, updated_at timestamptz default now(), supplier_name text, reorder_threshold integer not null default 10, reorder_qty integer not null default 20, expiry_date date, is_rx boolean not null default false, make text, model text, brand text, part_no text, grade text, "position" text, shelf text,
  cls text);                                                 -- clinic: medicine class for allergy checks (e.g. Penicillin)
create table if not exists public.purchase_orders (id text not null, shop_id uuid not null, po_number text not null, supplier_name text not null, items jsonb not null, status text not null default 'draft', created_by text, created_at timestamptz not null default now(), invoice_number text, invoice_photo text, received_at timestamptz, updated_at timestamptz not null default now());
create table if not exists public.refunds (id text not null, shop_id uuid not null, sale_id text, amount numeric, method text, reason text, restocked boolean, ts timestamptz, by text, updated_at timestamptz not null default now());
create table if not exists public.sales (id text not null, shop_id uuid, cashier text, till text, lines jsonb, subtotal numeric, tax numeric, total numeric, method text, tendered numeric, change numeric, mpesa_code text, btypes jsonb, ts timestamptz, synced boolean default true,
  patient_id text, patient_name text, patient_no text, visit_id text, visit_no text, copay_claim_id text);   -- clinic: who the bill was for
create table if not exists public.shop_auth_attempts (key text not null, fails integer not null default 0, window_start timestamptz not null default now(), locked_until timestamptz);
create table if not exists public.shop_devices (shop_id text not null, device_id text not null, label text, first_seen timestamptz not null default now(), last_seen timestamptz not null default now(), status text not null default 'active', over_plan boolean not null default false, removed_by text, removed_at timestamptz);
create table if not exists public.shop_payments (id uuid not null default gen_random_uuid(), shop_id uuid not null, amount numeric not null, months integer not null default 1, plan text, method text default 'mpesa', reference text, recorded_by text, paid_at timestamptz not null default now(), extends_to timestamptz);
create table if not exists public.shop_settings (shop_id uuid not null, key text not null, value jsonb, updated_at timestamptz default now());
create table if not exists public.staff (id text not null, shop_id uuid not null, name text, role text, pin text, active boolean default true, updated_at timestamptz default now(), email text);
create table if not exists public.staff_auth (staff_id text not null, auth_user_id uuid not null, created_at timestamptz not null default now());
create table if not exists public.staff_cash (id text not null, shop_id uuid not null, staff_id text, staff_name text, kind text not null default 'advance', amount numeric not null, reason text, recorded_by text, ts timestamptz not null default now(), status text not null default 'pending', reviewed_by text, reviewed_at timestamptz, review_note text, updated_at timestamptz not null default now(), recorded_by_id text);
create table if not exists public.stock_movements (id bigint generated always as identity, shop_id uuid, sku text, name text, qty numeric, cost numeric, btype text, ts timestamptz);
create table if not exists public.stock_ops (shop_id uuid not null, op_id text not null, created_at timestamptz not null default now());
create table if not exists public.stock_takes (id text not null, shop_id uuid not null, ts timestamptz not null, performed_by text, items jsonb not null, updated_at timestamptz not null default now());
create table if not exists public.table_orders (id text not null, shop_id uuid not null, label text not null, status text not null default 'open', lines jsonb not null default '[]'::jsonb, opened_by text, opened_at timestamptz not null default now(), settled_at timestamptz, settled_sale_id text, updated_at timestamptz not null default now(), bill_printed boolean default false, kitchen_round_count integer default 0);

-- ---------- keys ----------
do $$ begin if not exists (select 1 from pg_constraint where conname = 'shops_pkey') then execute 'alter table public.shops add constraint shops_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'audit_log_pkey') then execute 'alter table public.audit_log add constraint audit_log_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'cart_removal_requests_pkey') then execute 'alter table public.cart_removal_requests add constraint cart_removal_requests_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'customer_debts_pkey') then execute 'alter table public.customer_debts add constraint customer_debts_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'license_payment_requests_pkey') then execute 'alter table public.license_payment_requests add constraint license_payment_requests_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'mpesa_c2b_payments_pkey') then execute 'alter table public.mpesa_c2b_payments add constraint mpesa_c2b_payments_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'mpesa_requests_pkey') then execute 'alter table public.mpesa_requests add constraint mpesa_requests_pkey primary key (checkout_request_id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'payables_pkey') then execute 'alter table public.payables add constraint payables_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'pin_reset_config_pkey') then execute 'alter table public.pin_reset_config add constraint pin_reset_config_pkey primary key (k)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'pin_resets_pkey') then execute 'alter table public.pin_resets add constraint pin_resets_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'platform_admins_pkey') then execute 'alter table public.platform_admins add constraint platform_admins_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'platform_audit_log_pkey') then execute 'alter table public.platform_audit_log add constraint platform_audit_log_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'platform_business_types_pkey') then execute 'alter table public.platform_business_types add constraint platform_business_types_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'po_number_counters_pkey') then execute 'alter table public.po_number_counters add constraint po_number_counters_pkey primary key (shop_id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'product_tombstones_pkey') then execute 'alter table public.product_tombstones add constraint product_tombstones_pkey primary key (shop_id, sku)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'products_pkey') then execute 'alter table public.products add constraint products_pkey primary key (shop_id, sku)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'purchase_orders_pkey') then execute 'alter table public.purchase_orders add constraint purchase_orders_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'refunds_pkey') then execute 'alter table public.refunds add constraint refunds_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'sales_pkey') then execute 'alter table public.sales add constraint sales_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'shop_auth_attempts_pkey') then execute 'alter table public.shop_auth_attempts add constraint shop_auth_attempts_pkey primary key (key)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'shop_devices_pkey') then execute 'alter table public.shop_devices add constraint shop_devices_pkey primary key (shop_id, device_id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'shop_payments_pkey') then execute 'alter table public.shop_payments add constraint shop_payments_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'shop_settings_pkey') then execute 'alter table public.shop_settings add constraint shop_settings_pkey primary key (shop_id, key)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'staff_pkey') then execute 'alter table public.staff add constraint staff_pkey primary key (shop_id, id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'staff_auth_pkey') then execute 'alter table public.staff_auth add constraint staff_auth_pkey primary key (staff_id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'staff_cash_pkey') then execute 'alter table public.staff_cash add constraint staff_cash_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'stock_movements_pkey') then execute 'alter table public.stock_movements add constraint stock_movements_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'stock_ops_pkey') then execute 'alter table public.stock_ops add constraint stock_ops_pkey primary key (shop_id, op_id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'stock_takes_pkey') then execute 'alter table public.stock_takes add constraint stock_takes_pkey primary key (id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'table_orders_pkey') then execute 'alter table public.table_orders add constraint table_orders_pkey primary key (shop_id, id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'mpesa_c2b_payments_trans_id_key') then execute 'alter table public.mpesa_c2b_payments add constraint mpesa_c2b_payments_trans_id_key unique (trans_id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'platform_admins_pin_key') then execute 'alter table public.platform_admins add constraint platform_admins_pin_key unique (pin)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'staff_pin_unique') then execute 'alter table public.staff add constraint staff_pin_unique unique (pin)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'staff_auth_auth_user_id_key') then execute 'alter table public.staff_auth add constraint staff_auth_auth_user_id_key unique (auth_user_id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'cart_removal_requests_shop_id_fkey') then execute 'alter table public.cart_removal_requests add constraint cart_removal_requests_shop_id_fkey foreign key (shop_id) references public.shops(id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'customer_debts_shop_id_fkey') then execute 'alter table public.customer_debts add constraint customer_debts_shop_id_fkey foreign key (shop_id) references public.shops(id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'mpesa_requests_shop_id_fkey') then execute 'alter table public.mpesa_requests add constraint mpesa_requests_shop_id_fkey foreign key (shop_id) references public.shops(id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'payables_shop_id_fkey') then execute 'alter table public.payables add constraint payables_shop_id_fkey foreign key (shop_id) references public.shops(id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'pin_resets_shop_id_fkey') then execute 'alter table public.pin_resets add constraint pin_resets_shop_id_fkey foreign key (shop_id) references public.shops(id) on delete cascade'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'products_shop_id_fkey') then execute 'alter table public.products add constraint products_shop_id_fkey foreign key (shop_id) references public.shops(id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'sales_shop_id_fkey') then execute 'alter table public.sales add constraint sales_shop_id_fkey foreign key (shop_id) references public.shops(id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'shop_payments_shop_id_fkey') then execute 'alter table public.shop_payments add constraint shop_payments_shop_id_fkey foreign key (shop_id) references public.shops(id) on delete cascade'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'shop_settings_shop_id_fkey') then execute 'alter table public.shop_settings add constraint shop_settings_shop_id_fkey foreign key (shop_id) references public.shops(id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'staff_shop_id_fkey') then execute 'alter table public.staff add constraint staff_shop_id_fkey foreign key (shop_id) references public.shops(id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'stock_movements_shop_id_fkey') then execute 'alter table public.stock_movements add constraint stock_movements_shop_id_fkey foreign key (shop_id) references public.shops(id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'stock_takes_shop_id_fkey') then execute 'alter table public.stock_takes add constraint stock_takes_shop_id_fkey foreign key (shop_id) references public.shops(id)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'license_payment_requests_status_check') then execute 'alter table public.license_payment_requests add constraint license_payment_requests_status_check check (status = any (array[''pending'',''accepted'',''declined'']))'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'license_payment_requests_months_check') then execute 'alter table public.license_payment_requests add constraint license_payment_requests_months_check check (months >= 1 and months <= 24)'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'shop_devices_status_check') then execute 'alter table public.shop_devices add constraint shop_devices_status_check check (status = any (array[''active'',''removed'']))'; end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'shops_plan_check') then execute 'alter table public.shops add constraint shops_plan_check check (plan = any (array[''small'',''medium'',''large'',''xl'']))'; end if; end $$;

create index if not exists staff_cash_shop_idx on public.staff_cash (shop_id);
create unique index if not exists shops_shop_code_key on public.shops (shop_code);
create index if not exists pin_resets_lookup on public.pin_resets (shop_id, email, created_at desc);
create unique index if not exists license_pay_one_pending on public.license_payment_requests (shop_id) where status = 'pending';
create index if not exists audit_log_shop_ts on public.audit_log (shop_id, ts desc);
create index if not exists shop_devices_by_shop on public.shop_devices (shop_id, status, last_seen);
create index if not exists idx_po_shop_status on public.purchase_orders (shop_id, status);
create index if not exists license_pay_queue on public.license_payment_requests (status, requested_at);
create unique index if not exists license_pay_code_once on public.license_payment_requests (upper(mpesa_code)) where status = any (array['pending','accepted']);
create index if not exists shop_payments_shop_idx on public.shop_payments (shop_id, paid_at desc);
create unique index if not exists staff_active_pin_unique on public.staff (pin) where active = true;
create index if not exists staff_shop_email_lower on public.staff (shop_id, lower(email)) where email is not null;
create index if not exists idx_table_orders_shop_status on public.table_orders (shop_id, status);
create index if not exists sales_shop_ts on public.sales (shop_id, ts desc);
create index if not exists sales_visit on public.sales (shop_id, visit_id) where visit_id is not null;
