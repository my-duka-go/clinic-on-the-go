-- Clinic On the Go - database functions and triggers, copied from the live My DukaGO POS (20 Oct 2026).

create or replace function public.adjust_stock(p_shop_id text, p_sku text, p_delta numeric)
 returns table(sku text, stock numeric) language plpgsql set search_path to 'public' as $function$
begin
  if p_shop_id::uuid is distinct from public.jwt_shop_id() then
    raise exception 'shop mismatch' using errcode = '42501';
  end if;
  return query
    update public.products
       set stock = coalesce(products.stock, 0) + p_delta, updated_at = now()
     where products.shop_id = p_shop_id::uuid and products.sku = p_sku
    returning products.sku, products.stock;
end;
$function$;

create or replace function public.adjust_stock_v2(p_shop_id text, p_sku text, p_delta numeric, p_op_id text)
 returns table(sku text, stock numeric) language plpgsql security definer set search_path to 'public' as $function$
declare ins int;
begin
  if p_shop_id::uuid is distinct from public.jwt_shop_id() then
    raise exception 'shop mismatch' using errcode = '42501';
  end if;
  if p_op_id is not null and p_op_id <> '' then
    insert into public.stock_ops(shop_id, op_id) values (p_shop_id::uuid, p_op_id) on conflict do nothing;
    get diagnostics ins = row_count;
    if ins = 0 then
      return query select pr.sku, pr.stock from public.products pr where pr.shop_id = p_shop_id::uuid and pr.sku = p_sku;
      return;
    end if;
  end if;
  return query
    update public.products
       set stock = coalesce(products.stock, 0) + p_delta, updated_at = now()
     where products.shop_id = p_shop_id::uuid and products.sku = p_sku
    returning products.sku, products.stock;
end;
$function$;

create or replace function public.auth_attempt_clear(p_key text) returns void language sql security definer set search_path to 'public' as $function$
  update public.shop_auth_attempts set fails = 0, window_start = now(), locked_until = null where key = p_key;
$function$;

create or replace function public.auth_attempt_hit(p_key text, p_window_s integer, p_limit integer, p_lock_s integer)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare r public.shop_auth_attempts%rowtype;
begin
  insert into public.shop_auth_attempts (key, fails, window_start, locked_until) values (p_key, 0, now(), null)
  on conflict (key) do nothing;
  select * into r from public.shop_auth_attempts where key = p_key for update;
  if r.locked_until is not null and r.locked_until > now() then
    return jsonb_build_object('allowed', false, 'retry_seconds', ceil(extract(epoch from r.locked_until - now())));
  end if;
  if r.window_start < now() - make_interval(secs => p_window_s) then
    r.fails := 0; r.window_start := now();
  end if;
  r.fails := r.fails + 1;
  if r.fails > p_limit then
    update public.shop_auth_attempts set fails = 0, window_start = now(), locked_until = now() + make_interval(secs => p_lock_s)
     where key = p_key;
    return jsonb_build_object('allowed', false, 'retry_seconds', p_lock_s);
  end if;
  update public.shop_auth_attempts set fails = r.fails, window_start = r.window_start, locked_until = null where key = p_key;
  return jsonb_build_object('allowed', true, 'retry_seconds', 0);
end $function$;

create or replace function public.pin_hash(p_pin text) returns text language plpgsql security definer set search_path to 'public', 'extensions', 'vault' as $function$
declare k text;
begin
  if p_pin is null then return null; end if;
  select decrypted_secret into k from vault.decrypted_secrets where name = 'pin_pepper';
  if k is null then raise exception 'PIN key missing'; end if;
  return 'h1:' || length(p_pin) || ':'
      || encode(hmac(convert_to(left(p_pin, 4), 'utf8'), convert_to(k, 'utf8'), 'sha256'), 'hex') || ':'
      || encode(hmac(convert_to(p_pin, 'utf8'), convert_to(k, 'utf8'), 'sha256'), 'hex');
end $function$;

create or replace function public.pin_norm(p_x text) returns text language sql stable security definer set search_path to 'public', 'extensions', 'vault' as $function$
  select case when p_x is null then null when p_x like 'h1:%' then p_x else public.pin_hash(p_x) end
$function$;

create or replace function public.pin_clash(a text, b text) returns boolean language sql immutable set search_path to 'public' as $function$
  select a is not null and b is not null
     and split_part(a, ':', 3) = split_part(b, ':', 3)
     and (split_part(a, ':', 2) <> split_part(b, ':', 2) or a = b)
$function$;

create or replace function public.pin_matches(p_stored text, p_plain text) returns boolean language sql stable security definer set search_path to 'public', 'extensions', 'vault' as $function$
  select p_stored is not null and p_plain is not null and (p_stored = public.pin_hash(p_plain) or p_stored = p_plain)
$function$;

create or replace function public.pin_in_use(p_pin text, p_exclude text) returns boolean language sql stable security definer set search_path to 'public', 'extensions', 'vault' as $function$
  select exists (
    select 1 from public.staff s
     where s.active = true and s.pin is not null
       and s.id <> coalesce(p_exclude, '')
       and public.pin_clash(public.pin_norm(s.pin), public.pin_hash(p_pin)))
$function$;

create or replace function public.pin_login_hint(p_shop text, p_pin text) returns text language sql stable security definer set search_path to 'public', 'extensions', 'vault' as $function$
  select case
    when length(p_pin) = 4 and exists (
      select 1 from public.staff s
       where s.shop_id::text = p_shop and s.active = true and s.pin is not null
         and split_part(public.pin_norm(s.pin), ':', 2)::int > 4
         and split_part(public.pin_norm(s.pin), ':', 3) = split_part(public.pin_hash(p_pin), ':', 3)) then 'prefix'
    when exists (
      select 1 from public.staff s
       where s.shop_id::text <> p_shop and s.active = true and s.pin is not null
         and public.pin_norm(s.pin) = public.pin_hash(p_pin)) then 'other_shop'
    else 'not_found' end
$function$;

create or replace function public.check_pin_prefix_collision() returns trigger language plpgsql security definer set search_path to 'public', 'extensions', 'vault' as $function$
begin
  if new.active = true and new.pin is not null then
    if exists (select 1 from public.staff s
                where s.active = true and s.id <> new.id and s.pin is not null
                  and public.pin_clash(public.pin_norm(s.pin), public.pin_norm(new.pin))) then
      raise exception 'PIN conflicts with an existing active staff PIN (exact match or prefix)';
    end if;
  end if;
  return new;
end $function$;

create or replace function public.scramble_staff_pin() returns trigger language plpgsql security definer set search_path to 'public', 'extensions', 'vault' as $function$
begin
  if new.pin is not null and new.pin not like 'h1:%' then
    new.pin := public.pin_hash(new.pin);
  end if;
  return new;
end $function$;

create or replace function public.pin_reset_try(p_id uuid, p_max integer, p_refund boolean default false) returns integer language plpgsql security definer set search_path to 'public' as $function$
declare n integer;
begin
  if p_refund then
    update public.pin_resets set attempts = greatest(attempts - 1, 0) where id = p_id returning attempts into n;
    return n;
  end if;
  update public.pin_resets set attempts = attempts + 1
   where id = p_id and used_at is null and expires_at > now() and attempts < p_max
  returning attempts into n;
  if n is null then
    update public.pin_resets set used_at = coalesce(used_at, now()) where id = p_id;
  end if;
  return n;
end $function$;

create or replace function public.plan_device_limit(p_plan text) returns integer language sql immutable set search_path to 'public' as $function$
  select case coalesce(p_plan, 'small') when 'medium' then 3 when 'large' then 5 when 'xl' then 100000 else 2 end
$function$;
create or replace function public.plan_monthly_price(p_plan text) returns numeric language sql immutable set search_path to 'public' as $function$
  select (case coalesce(p_plan, 'small') when 'medium' then 1500 when 'large' then 1800 when 'xl' then 2500 else 1200 end)::numeric
$function$;
create or replace function public.plan_yearly_price(p_plan text) returns numeric language sql immutable set search_path to 'public' as $function$
  select round(public.plan_monthly_price(p_plan) * 12 * 0.90)
$function$;

create or replace function public.next_po_number(p_shop_id uuid) returns text language plpgsql set search_path to 'public' as $function$
declare
  v_num integer;
  v_year text := to_char(now(), 'YYYY');
begin
  insert into po_number_counters (shop_id, last_number)
  values (p_shop_id, 1)
  on conflict (shop_id) do update set last_number = po_number_counters.last_number + 1
  returning last_number into v_num;
  return 'PO-' || v_year || '-' || lpad(v_num::text, 4, '0');
end;
$function$;

create or replace function public.product_tombstone_add() returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  insert into public.product_tombstones(shop_id, sku, deleted_at) values (old.shop_id, old.sku, now()) on conflict (shop_id, sku) do update set deleted_at = now();
  return old;
end $function$;
create or replace function public.product_tombstone_clear() returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  delete from public.product_tombstones where shop_id = new.shop_id and sku = new.sku;
  return new;
end $function$;

create or replace function public.license_status(p_shop_id text) returns jsonb language sql stable security definer set search_path to 'public' as $function$
  select case when public.jwt_shop_id()::text = p_shop_id then
    jsonb_build_object(
      'ok', true,
      'active', s.active is not false,
      'license_status', s.license_status,
      'note', s.license_note,
      'expires_at', s.license_expires_at,
      'plan', coalesce(s.plan, 'small'),
      'cycle', coalesce(s.license_cycle, 'monthly'),
      'monthly_price', public.plan_monthly_price(coalesce(s.plan, 'small')),
      'yearly_price', public.plan_yearly_price(coalesce(s.plan, 'small')),
      'shop_code', s.shop_code,
      'name', s.name,
      'request', (
        select jsonb_build_object(
                 'status', r.status, 'mpesa_code', r.mpesa_code, 'amount', r.amount, 'months', r.months, 'cycle', r.cycle,
                 'requested_at', r.requested_at, 'decided_at', r.decided_at, 'note', r.decision_note)
          from public.license_payment_requests r
         where r.shop_id = p_shop_id
         order by r.requested_at desc
         limit 1))
  else
    jsonb_build_object(
      'ok', true,
      'active', s.active is not false,
      'license_status', s.license_status,
      'note', s.license_note,
      'expires_at', s.license_expires_at,
      'plan', coalesce(s.plan, 'small'),
      'cycle', coalesce(s.license_cycle, 'monthly'),
      'monthly_price', public.plan_monthly_price(coalesce(s.plan, 'small')),
      'yearly_price', public.plan_yearly_price(coalesce(s.plan, 'small')),
      'request', null)
  end
  from public.shops s
  where s.id::text = p_shop_id;
$function$;

create or replace function public.license_request_decided() returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
  v_expires timestamptz;
  v_new     timestamptz;
begin
  if new.status = old.status then
    return new;
  end if;
  if old.status <> 'pending' then
    raise exception 'This payment request was already % and cannot be changed', old.status;
  end if;
  new.decided_at := now();
  if new.status = 'accepted' then
    select s.license_expires_at into v_expires
      from public.shops s where s.id::text = new.shop_id for update;
    if not found then
      raise exception 'Clinic % was not found - nothing was accepted', new.shop_id;
    end if;
    v_new := greatest(now(), coalesce(v_expires, now()))
             + case when new.cycle = 'yearly' then interval '365 days'
                    else make_interval(months => new.months) end;
    update public.shops s
       set active = true,
           license_status = 'active',
           license_note = null,
           license_expires_at = v_new,
           plan = coalesce(new.plan, s.plan),
           license_cycle = coalesce(new.cycle, s.license_cycle, 'monthly')
     where s.id::text = new.shop_id;
    insert into public.shop_payments (shop_id, amount, months, plan, reference, recorded_by, extends_to)
    select s.id, new.amount, new.months, coalesce(new.plan, s.plan), new.mpesa_code,
           coalesce(new.decided_by, 'Platform Admin'), v_new
      from public.shops s where s.id::text = new.shop_id;
    new.extends_to := v_new;
  end if;
  return new;
end;
$function$;

create or replace function public.register_device(p_shop_id text, p_device_id text, p_label text default null, p_existing boolean default false, p_admin_pin text default null, p_accept_upgrade boolean default false)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_plan   text;
  v_limit  integer;
  v_count  integer;
  v_dev    text := left(coalesce(p_device_id, ''), 80);
  v_label  text := nullif(left(coalesce(p_label, ''), 80), '');
  v_status text;
  v_seen   timestamptz;
  v_over   boolean;
  v_has    boolean := false;
  v_admin  text;
  v_name   text;
begin
  if length(v_dev) < 6 then
    return jsonb_build_object('ok', false, 'code', 'bad_device');
  end if;
  select coalesce(s.plan, 'small'), s.name into v_plan, v_name
    from public.shops s where s.id::text = p_shop_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'no_shop');
  end if;
  v_limit := public.plan_device_limit(v_plan);
  -- Test clinics (name contains "test" or "trial") have no device limit.
  if (v_name ilike '%test%' or v_name ilike '%trial%') then v_limit := 1000; end if;

  select d.status, d.last_seen, d.over_plan into v_status, v_seen, v_over
    from public.shop_devices d where d.shop_id = p_shop_id and d.device_id = v_dev;
  v_has := found;

  if v_has and v_status = 'active' and v_seen > now() - interval '30 days' then
    update public.shop_devices d set last_seen = now(), label = coalesce(v_label, d.label)
     where d.shop_id = p_shop_id and d.device_id = v_dev;
    select count(*) into v_count from public.shop_devices d
     where d.shop_id = p_shop_id and d.status = 'active' and d.last_seen > now() - interval '30 days';
    v_over := v_count > v_limit;
    update public.shop_devices d2 set over_plan = (v_count > v_limit) where d2.shop_id = p_shop_id and d2.status = 'active' and d2.over_plan is distinct from (v_count > v_limit);
    return jsonb_build_object('ok', true, 'count', v_count, 'limit', v_limit, 'plan', v_plan, 'over_plan', v_over);
  end if;

  if v_has and v_status = 'removed' and p_existing then
    return jsonb_build_object('ok', false, 'code', 'removed', 'limit', v_limit, 'plan', v_plan);
  end if;

  select count(*) into v_count from public.shop_devices d
   where d.shop_id = p_shop_id and d.status = 'active' and d.last_seen > now() - interval '30 days'
     and d.device_id <> v_dev;

  if p_admin_pin is not null then
    select t.name into v_admin from public.staff t
     where t.shop_id::text = p_shop_id and public.pin_matches(t.pin, p_admin_pin) and t.role = 'admin' and t.active is not false
     limit 1;
    if v_admin is null then
      return jsonb_build_object('ok', false, 'code', 'bad_pin', 'count', v_count, 'limit', v_limit, 'plan', v_plan);
    end if;
  end if;

  if v_has and v_status = 'removed' and v_admin is null then
    return jsonb_build_object('ok', false, 'code', 'needs_admin', 'count', v_count, 'limit', v_limit, 'plan', v_plan);
  end if;

  if v_count < v_limit then
    insert into public.shop_devices (shop_id, device_id, label) values (p_shop_id, v_dev, v_label)
    on conflict (shop_id, device_id) do update
      set status = 'active', last_seen = now(), label = coalesce(excluded.label, public.shop_devices.label),
          over_plan = false, removed_by = null, removed_at = null;
    return jsonb_build_object('ok', true, 'count', v_count + 1, 'limit', v_limit, 'plan', v_plan, 'over_plan', false);
  end if;

  if v_plan = 'large' then
    if p_accept_upgrade and v_admin is not null then
      update public.shops s set plan = 'xl' where s.id::text = p_shop_id;
      insert into public.shop_devices (shop_id, device_id, label) values (p_shop_id, v_dev, v_label)
      on conflict (shop_id, device_id) do update
        set status = 'active', last_seen = now(), label = coalesce(excluded.label, public.shop_devices.label),
            over_plan = false, removed_by = null, removed_at = null;
      return jsonb_build_object('ok', true, 'upgraded', true, 'count', v_count + 1,
                                'limit', public.plan_device_limit('xl'), 'plan', 'xl', 'price', public.plan_monthly_price('xl'));
    end if;
    return jsonb_build_object('ok', false, 'code', 'needs_upgrade', 'count', v_count, 'limit', v_limit,
                              'plan', v_plan, 'price', public.plan_monthly_price('xl'));
  end if;

  return jsonb_build_object('ok', false, 'code', 'limit', 'count', v_count, 'limit', v_limit, 'plan', v_plan);
end;
$function$;

create or replace function public.remove_device(p_shop_id text, p_pin text, p_device_id text) returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_admin text;
  v_n     integer;
begin
  select t.name into v_admin from public.staff t
   where t.shop_id::text = p_shop_id and public.pin_matches(t.pin, p_pin) and t.role = 'admin' and t.active is not false limit 1;
  if v_admin is null then
    return jsonb_build_object('ok', false, 'code', 'bad_pin');
  end if;
  update public.shop_devices d
     set status = 'removed', removed_by = v_admin, removed_at = now()
   where d.shop_id = p_shop_id and d.device_id = p_device_id and d.status = 'active';
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n > 0, 'code', case when v_n > 0 then null else 'not_found' end);
end;
$function$;

create or replace function public.shop_devices_list(p_shop_id text, p_pin text) returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_plan  text;
  v_admin text;
begin
  select t.name into v_admin from public.staff t
   where t.shop_id::text = p_shop_id and public.pin_matches(t.pin, p_pin) and t.role = 'admin' and t.active is not false limit 1;
  if v_admin is null then
    return jsonb_build_object('ok', false, 'code', 'bad_pin');
  end if;
  select coalesce(s.plan, 'small') into v_plan from public.shops s where s.id::text = p_shop_id;
  return jsonb_build_object(
    'ok', true, 'plan', v_plan, 'limit', public.plan_device_limit(v_plan),
    'count', (select count(*) from public.shop_devices d
               where d.shop_id = p_shop_id and d.status = 'active' and d.last_seen > now() - interval '30 days'),
    'devices', coalesce((
      select jsonb_agg(jsonb_build_object(
               'device_id', d.device_id, 'label', d.label, 'first_seen', d.first_seen, 'last_seen', d.last_seen,
               'status', d.status, 'over_plan', d.over_plan,
               'counted', d.status = 'active' and d.last_seen > now() - interval '30 days')
             order by d.last_seen desc)
        from public.shop_devices d
       where d.shop_id = p_shop_id and d.status = 'active'), '[]'::jsonb));
end;
$function$;

create or replace function public.submit_license_payment(p_shop_id text, p_pin text, p_mpesa_code text, p_months integer default 1, p_cycle text default 'monthly')
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_name   text;
  v_scode  text;
  v_plan   text;
  v_role   text;
  v_who    text;
  v_code   text := upper(regexp_replace(coalesce(p_mpesa_code, ''), '\s', '', 'g'));
  v_cycle  text := case when lower(coalesce(p_cycle, 'monthly')) = 'yearly' then 'yearly' else 'monthly' end;
  v_months integer := greatest(1, least(coalesce(p_months, 1), 24));
  v_amount numeric;
  v_recent integer;
  v_id     uuid;
begin
  select s.name, s.shop_code, coalesce(s.plan, 'small') into v_name, v_scode, v_plan
    from public.shops s where s.id::text = p_shop_id;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'no_shop');
  end if;
  select t.role, t.name into v_role, v_who
    from public.staff t
   where t.shop_id::text = p_shop_id and public.pin_matches(t.pin, p_pin) and t.active is not false
   limit 1;
  if v_role is null then
    return jsonb_build_object('ok', false, 'code', 'bad_pin');
  end if;
  if v_role <> 'admin' then
    return jsonb_build_object('ok', false, 'code', 'not_admin');
  end if;
  if v_code !~ '^[A-Z0-9]{10}$' or v_code !~ '[A-Z]' or v_code !~ '[0-9]' then
    return jsonb_build_object('ok', false, 'code', 'bad_code');
  end if;
  if exists (select 1 from public.license_payment_requests r
              where upper(r.mpesa_code) = v_code
                and (r.status = 'accepted' or (r.status = 'pending' and r.shop_id <> p_shop_id))) then
    return jsonb_build_object('ok', false, 'code', 'code_used');
  end if;
  select count(*) into v_recent from public.license_payment_requests r
   where r.shop_id = p_shop_id and r.status = 'declined' and r.decided_at > now() - interval '24 hours';
  if v_recent >= 5 then
    return jsonb_build_object('ok', false, 'code', 'too_many');
  end if;
  if v_cycle = 'yearly' then
    v_months := 12;
    v_amount := public.plan_yearly_price(v_plan);
  else
    v_amount := public.plan_monthly_price(v_plan) * v_months;
  end if;
  update public.license_payment_requests r
     set mpesa_code = v_code, months = v_months, amount = v_amount, plan = v_plan, cycle = v_cycle,
         requested_by = v_who, requested_at = now(), shop_name = v_name, shop_code = v_scode
   where r.shop_id = p_shop_id and r.status = 'pending'
  returning r.id into v_id;
  if v_id is null then
    insert into public.license_payment_requests (shop_id, shop_name, shop_code, mpesa_code, amount, months, plan, cycle, requested_by)
    values (p_shop_id, v_name, v_scode, v_code, v_amount, v_months, v_plan, v_cycle, v_who)
    returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'amount', v_amount, 'months', v_months, 'cycle', v_cycle, 'mpesa_code', v_code);
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'code', 'code_used');
end;
$function$;

create or replace function public.suspend_expired_shops() returns integer language plpgsql set search_path to 'public' as $function$
declare n integer;
begin
  update public.shops
     set active = false, license_status = 'suspended',
         license_note = coalesce(nullif(license_note,''), 'Subscription expired - please renew to continue')
   where license_expires_at is not null
     and license_expires_at + interval '7 days' < now()
     and active is not false;
  get diagnostics n = row_count;
  return n;
end $function$;

create or replace function public.sync_staff_auth() returns trigger language plpgsql security definer set search_path to 'public', 'auth' as $function$
declare uid uuid;
begin
  if tg_op = 'DELETE' then
    select auth_user_id into uid from public.staff_auth where staff_id = old.id;
    if uid is not null then update auth.users set banned_until = 'infinity' where id = uid; end if;
    return old;
  end if;
  select auth_user_id into uid from public.staff_auth where staff_id = new.id;
  if uid is not null then
    update auth.users set
      raw_app_meta_data = coalesce(raw_app_meta_data,'{}'::jsonb) || jsonb_build_object('shop_id', new.shop_id, 'staff_id', new.id, 'role', new.role),
      banned_until = case when new.active is false then 'infinity'::timestamptz else null end
    where id = uid;
  end if;
  return new;
end $function$;

-- ---------- triggers ----------
create or replace trigger a_staff_pin_scramble before insert or update of pin on public.staff for each row execute function public.scramble_staff_pin();
create or replace trigger staff_pin_prefix_check before insert or update of pin, active on public.staff for each row execute function public.check_pin_prefix_collision();
create or replace trigger staff_auth_sync after delete or update of role, active, shop_id on public.staff for each row execute function public.sync_staff_auth();
create or replace trigger a_platform_pin_scramble before insert or update of pin on public.platform_admins for each row execute function public.scramble_staff_pin();
create or replace trigger license_request_decided before update on public.license_payment_requests for each row execute function public.license_request_decided();
create or replace trigger products_tombstone_add after delete on public.products for each row execute function public.product_tombstone_add();
create or replace trigger products_tombstone_clear after insert or update of sku on public.products for each row execute function public.product_tombstone_clear();
