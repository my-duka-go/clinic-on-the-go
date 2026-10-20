-- Safe to run again: existing rules are replaced, existing tables and keys are kept.
-- Clinic On the Go - clinic tables, row-level security, grants, the PIN key and the hourly licence check.

-- ---------- clinic records ----------
-- Each record is kept whole in `doc` (the same object the phone stores), with a few columns pulled out for
-- searching and reports. Every row belongs to one clinic (shop_id) and is only visible to that clinic's staff.
create table if not exists public.patients (
  shop_id uuid not null references public.shops(id), id text not null, doc jsonb not null,
  updated_at timestamptz not null default now(), created_at timestamptz not null default now(),
  patient_no text generated always as (doc->>'patient_no') stored,
  full_name text generated always as (doc->>'full_name') stored,
  primary key (shop_id, id));
create table if not exists public.visits (
  shop_id uuid not null references public.shops(id), id text not null, doc jsonb not null,
  updated_at timestamptz not null default now(), created_at timestamptz not null default now(),
  patient_id text generated always as (doc->>'patient_id') stored,
  status text generated always as (doc->>'status') stored,
  checked_in_at text generated always as (doc->>'checked_in_at') stored,
  primary key (shop_id, id));
create table if not exists public.appointments (
  shop_id uuid not null references public.shops(id), id text not null, doc jsonb not null,
  updated_at timestamptz not null default now(), created_at timestamptz not null default now(),
  patient_id text generated always as (doc->>'patient_id') stored,
  appt_date text generated always as (doc->>'date') stored,
  status text generated always as (doc->>'status') stored,
  primary key (shop_id, id));
create table if not exists public.dispensing (
  shop_id uuid not null references public.shops(id), id text not null, doc jsonb not null,
  updated_at timestamptz not null default now(), created_at timestamptz not null default now(),
  patient_id text generated always as (doc->>'patient_id') stored,
  sku text generated always as (doc->>'sku') stored,
  primary key (shop_id, id));
create index if not exists patients_changed on public.patients (shop_id, updated_at);
create index if not exists patients_no on public.patients (shop_id, patient_no);
create index if not exists visits_changed on public.visits (shop_id, updated_at);
create index if not exists visits_patient on public.visits (shop_id, patient_id);
create index if not exists visits_status on public.visits (shop_id, status);
create index if not exists appointments_changed on public.appointments (shop_id, updated_at);
create index if not exists appointments_day on public.appointments (shop_id, appt_date);
create index if not exists dispensing_changed on public.dispensing (shop_id, updated_at);

-- ---------- row-level security: a clinic sees only its own rows ----------
do $$ declare t text; begin
  foreach t in array array['shops','audit_log','cart_removal_requests','customer_debts','license_payment_requests','mpesa_c2b_payments',
    'mpesa_requests','payables','pin_reset_config','pin_resets','platform_admins','platform_audit_log','platform_business_types',
    'po_number_counters','product_tombstones','products','purchase_orders','refunds','sales','shop_auth_attempts','shop_devices',
    'shop_payments','shop_settings','staff','staff_auth','staff_cash','stock_movements','stock_ops','stock_takes','table_orders',
    'patients','visits','appointments','dispensing'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

do $$ declare t text; begin
  foreach t in array array['audit_log','cart_removal_requests','customer_debts','payables','po_number_counters','products','purchase_orders',
    'refunds','sales','shop_settings','staff_cash','stock_movements','stock_takes','table_orders','patients','visits','appointments','dispensing'] loop
    execute format('drop policy if exists shop_isolation on public.%I', t);
    execute format('create policy shop_isolation on public.%I as permissive for all to authenticated using (shop_id = public.jwt_shop_id()) with check (shop_id = public.jwt_shop_id())', t);
  end loop;
end $$;
drop policy if exists shop_isolation on public.product_tombstones;
create policy shop_isolation on public.product_tombstones as permissive for all to authenticated using (shop_id = public.jwt_shop_id()) with check (shop_id = public.jwt_shop_id());
drop policy if exists staff_read on public.staff;
create policy staff_read on public.staff as permissive for select to authenticated using (shop_id = public.jwt_shop_id());
drop policy if exists staff_write on public.staff;
create policy staff_write on public.staff as permissive for all to authenticated using (shop_id = public.jwt_shop_id() and public.jwt_role() = 'admin') with check (shop_id = public.jwt_shop_id() and public.jwt_role() = 'admin');
drop policy if exists shop_read_own on public.shops;
create policy shop_read_own on public.shops as permissive for select to authenticated using (id = public.jwt_shop_id());
drop policy if exists mpesa_req_read on public.mpesa_requests;
create policy mpesa_req_read on public.mpesa_requests as permissive for select to authenticated using (shop_id = public.jwt_shop_id());
drop policy if exists pbt_read on public.platform_business_types;
create policy pbt_read on public.platform_business_types as permissive for select to authenticated using (true);
drop policy if exists shop_pay_read on public.shop_payments;
create policy shop_pay_read on public.shop_payments as permissive for select to authenticated using (shop_id = public.jwt_shop_id());

-- ---------- grants: nothing for anonymous callers; signed-in staff only through the policies above ----------
revoke all on all tables in schema public from anon, authenticated;
grant select, insert, update, delete on public.audit_log, public.cart_removal_requests, public.customer_debts, public.mpesa_requests,
  public.payables, public.platform_business_types, public.po_number_counters, public.product_tombstones, public.products,
  public.purchase_orders, public.refunds, public.sales, public.shop_payments, public.shop_settings, public.shops, public.staff,
  public.staff_cash, public.stock_movements, public.stock_takes, public.table_orders,
  public.patients, public.visits, public.appointments, public.dispensing to authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;

-- functions: only the ones the app calls directly are open; the rest run inside the server functions (service role)
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.jwt_shop_id(), public.jwt_role(), public.gen_shop_code(), public.pin_clash(text, text),
  public.plan_device_limit(text), public.plan_monthly_price(text), public.plan_yearly_price(text), public.next_po_number(uuid),
  public.license_status(text) to anon, authenticated;
grant execute on function public.adjust_stock(text, text, numeric), public.adjust_stock_v2(text, text, numeric, text) to authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- ---------- the key PINs are scrambled with (its own, not the POS's) ----------
select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'pin_pepper', 'Key for scrambling staff PINs')
 where not exists (select 1 from vault.secrets where name = 'pin_pepper');

-- ---------- hourly: switch off clinics more than 7 days past their paid-until date ----------
select cron.schedule('suspend-expired-shops', '15 * * * *', 'select public.suspend_expired_shops();');
