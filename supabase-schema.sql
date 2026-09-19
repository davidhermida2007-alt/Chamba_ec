-- CHAMBA EC V3 — Base de datos
-- Ejecutar completo en Supabase SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.plans (
  id text primary key,
  name text not null,
  price numeric(10,2) not null default 0 check (price >= 0),
  duration_days integer not null check (duration_days > 0),
  max_vacancies integer not null default 1 check (max_vacancies > 0),
  featured boolean not null default false,
  urgent boolean not null default false,
  enabled boolean not null default true,
  public_plan boolean not null default true,
  description text,
  sort_order integer not null default 100,
  updated_at timestamptz not null default now()
);

insert into public.plans(id,name,price,duration_days,max_vacancies,featured,urgent,enabled,public_plan,description,sort_order)
values
('first_free','Prueba gratis',0,3,1,false,false,true,true,'Primera vacante gratis por 3 días. Luego puede renovarse al plan Básico de $1 por 7 días.',10),
('basic','Básico',1,7,1,false,false,true,true,'Una vacante normal durante 7 días.',20),
('standard','Estándar',2,15,1,false,false,true,true,'Una vacante normal durante 15 días.',30),
('featured','Destacado',4,15,1,true,false,true,true,'Aparece antes que las normales durante 15 días.',40),
('urgent','Urgente',5,7,1,true,true,true,true,'Prioridad alta y etiqueta URGENTE durante 7 días.',50),
('company','Empresa',10,30,5,true,false,true,true,'Hasta 5 vacantes durante 30 días.',60),
('manual','Curada por Chamba EC',0,30,1,false,false,true,false,'Vacante agregada por administración.',999)
on conflict (id) do update set
name=excluded.name,price=excluded.price,duration_days=excluded.duration_days,max_vacancies=excluded.max_vacancies,
featured=excluded.featured,urgent=excluded.urgent,enabled=excluded.enabled,public_plan=excluded.public_plan,
description=excluded.description,sort_order=excluded.sort_order,updated_at=now();

create table if not exists public.job_submissions (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  publisher_name text not null,
  publisher_email text,
  company text not null,
  title text not null,
  province text not null,
  city text not null,
  area text not null,
  employment text,
  modality text not null default 'Presencial',
  pay text,
  requirements text not null,
  description text not null,
  contact text not null,
  contact_type text not null default 'WhatsApp',
  plan_id text not null references public.plans(id),
  price_snapshot numeric(10,2) not null default 0,
  duration_days integer not null default 7,
  max_vacancies integer not null default 1,
  is_featured boolean not null default false,
  is_urgent boolean not null default false,
  status text not null default 'pending' check (status in ('pending','approved','rejected','expired')),
  payment_status text not null default 'pending' check (payment_status in ('pending','verified','waived')),
  payment_reference text,
  starts_at timestamptz,
  expires_at timestamptz,
  terms_accepted boolean not null default false,
  renewal_plan_id text references public.plans(id),
  renewal_requested boolean not null default false
);

create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create or replace function public.is_chamba_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(select 1 from public.admins a where a.user_id = auth.uid());
$$;

create or replace function public.apply_plan_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare p public.plans;
begin
  select * into p from public.plans where id = new.plan_id and enabled = true;
  if not found then raise exception 'Plan no válido'; end if;

  new.price_snapshot := p.price;
  new.duration_days := p.duration_days;
  new.max_vacancies := p.max_vacancies;
  new.is_featured := p.featured;
  new.is_urgent := p.urgent;
  new.updated_at := now();

  if new.plan_id = 'first_free' then
    new.renewal_plan_id := 'basic';
  end if;

  if tg_op = 'INSERT' then
    new.status := 'pending';
    new.payment_status := 'pending';
    new.starts_at := null;
    new.expires_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_apply_plan_snapshot on public.job_submissions;
create trigger trg_apply_plan_snapshot
before insert or update of plan_id on public.job_submissions
for each row execute function public.apply_plan_snapshot();

create or replace function public.prepare_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at := now();

  if new.status = 'approved' and old.status is distinct from 'approved' then
    if new.price_snapshot > 0 and new.payment_status <> 'verified' and new.payment_status <> 'waived' then
      raise exception 'Debes verificar o exonerar el pago antes de aprobar.';
    end if;
    new.starts_at := coalesce(new.starts_at, now());
    new.expires_at := now() + make_interval(days => new.duration_days);
  end if;

  if new.status = 'rejected' then
    new.starts_at := null;
    new.expires_at := null;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_prepare_approval on public.job_submissions;
create trigger trg_prepare_approval
before update on public.job_submissions
for each row execute function public.prepare_approval();

-- Una sola “primera publicación gratis” por número de contacto.
create unique index if not exists one_first_free_per_contact
on public.job_submissions(contact)
where plan_id='first_free' and status <> 'rejected';


-- Renovación de prueba gratis al plan Básico.
-- No hace un cobro automático: el administrador confirma primero que recibió $1.
create or replace function public.renew_free_trial_to_basic(p_job_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare j public.job_submissions;
declare p public.plans;
begin
  if not public.is_chamba_admin() then
    raise exception 'No autorizado';
  end if;

  select * into j from public.job_submissions where id=p_job_id for update;
  if not found then raise exception 'Oferta no encontrada'; end if;
  if j.plan_id <> 'first_free' then raise exception 'No es una prueba gratis'; end if;
  if j.payment_status <> 'verified' then raise exception 'Primero confirma el pago de $1'; end if;

  select * into p from public.plans where id='basic' and enabled=true;
  if not found then raise exception 'Plan Básico no disponible'; end if;

  update public.job_submissions
  set plan_id='basic',
      price_snapshot=p.price,
      duration_days=p.duration_days,
      max_vacancies=p.max_vacancies,
      is_featured=p.featured,
      is_urgent=p.urgent,
      status='approved',
      starts_at=now(),
      expires_at=now()+make_interval(days=>p.duration_days),
      renewal_requested=false,
      updated_at=now()
  where id=p_job_id;
end;
$$;

-- RLS
alter table public.plans enable row level security;
alter table public.job_submissions enable row level security;
alter table public.admins enable row level security;

drop policy if exists "public_read_plans" on public.plans;
create policy "public_read_plans" on public.plans
for select to anon, authenticated using (enabled = true and public_plan = true or public.is_chamba_admin());

drop policy if exists "admin_update_plans" on public.plans;
create policy "admin_update_plans" on public.plans
for update to authenticated using (public.is_chamba_admin()) with check (public.is_chamba_admin());

drop policy if exists "public_submit_pending_jobs" on public.job_submissions;
create policy "public_submit_pending_jobs" on public.job_submissions
for insert to anon, authenticated
with check (
  terms_accepted = true
  and plan_id in (select id from public.plans where enabled=true and public_plan=true)
);

drop policy if exists "public_read_approved_jobs" on public.job_submissions;
create policy "public_read_approved_jobs" on public.job_submissions
for select to anon, authenticated
using (
  (status='approved' and expires_at > now())
  or public.is_chamba_admin()
);

drop policy if exists "admin_insert_jobs" on public.job_submissions;
create policy "admin_insert_jobs" on public.job_submissions
for insert to authenticated with check (public.is_chamba_admin());

drop policy if exists "admin_update_jobs" on public.job_submissions;
create policy "admin_update_jobs" on public.job_submissions
for update to authenticated using (public.is_chamba_admin()) with check (public.is_chamba_admin());

drop policy if exists "admin_delete_jobs" on public.job_submissions;
create policy "admin_delete_jobs" on public.job_submissions
for delete to authenticated using (public.is_chamba_admin());

drop policy if exists "admin_read_self" on public.admins;
create policy "admin_read_self" on public.admins
for select to authenticated using (user_id = auth.uid());

-- Para convertir tu cuenta de Supabase en administrador:
-- 1) Crea tu usuario en Authentication > Users.
-- 2) Copia su UUID.
-- 3) Ejecuta:
-- insert into public.admins(user_id) values ('PEGA_AQUI_EL_UUID');



-- =========================================================
-- CHAMBA EC V3.1 — PAQUETES REALES DE PUBLICACIONES
-- Ejecutar UNA SOLA VEZ en Supabase SQL Editor.
-- =========================================================

-- 1) Nuevas cantidades por plan.
update public.plans set
  max_vacancies = case id
    when 'first_free' then 1
    when 'basic' then 2
    when 'standard' then 3
    when 'featured' then 4
    when 'urgent' then 5
    when 'company' then 10
    else max_vacancies
  end,
  description = case id
    when 'first_free' then '1 publicación gratis por 3 días. Al terminar puede renovarse al Básico de $1 por 7 días.'
    when 'basic' then 'Hasta 2 publicaciones durante 7 días.'
    when 'standard' then 'Hasta 3 publicaciones durante 15 días.'
    when 'featured' then 'Hasta 4 publicaciones destacadas durante 15 días.'
    when 'urgent' then 'Hasta 5 publicaciones urgentes durante 7 días.'
    when 'company' then 'Hasta 10 publicaciones durante 30 días.'
    else description
  end,
  updated_at = now()
where id in ('first_free','basic','standard','featured','urgent','company');

-- 2) Un "paquete" representa UNA compra y contiene varias publicaciones.
create table if not exists public.posting_orders (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  plan_id text not null references public.plans(id),
  publisher_name text not null,
  publisher_email text,
  company text not null,
  contact text not null,
  access_code text not null unique default encode(gen_random_bytes(16),'hex'),
  price_snapshot numeric(10,2) not null default 0,
  duration_days integer not null default 7,
  max_publications integer not null default 1 check (max_publications > 0),
  used_publications integer not null default 0 check (used_publications >= 0),
  is_featured boolean not null default false,
  is_urgent boolean not null default false,
  payment_status text not null default 'pending' check (payment_status in ('pending','verified','waived')),
  status text not null default 'pending' check (status in ('pending','active','expired','cancelled')),
  starts_at timestamptz,
  expires_at timestamptz
);

alter table public.job_submissions
  add column if not exists order_id uuid references public.posting_orders(id) on delete set null;

create index if not exists idx_job_submissions_order_id on public.job_submissions(order_id);

-- Una sola prueba gratis por número.
create unique index if not exists one_free_order_per_contact
on public.posting_orders(contact)
where plan_id='first_free' and status <> 'cancelled';

-- 3) Crear un paquete + su primera publicación.
create or replace function public.create_posting_order_with_job(
  p_plan_id text,
  p_publisher_name text,
  p_publisher_email text,
  p_company text,
  p_contact text,
  p_title text,
  p_area text,
  p_province text,
  p_city text,
  p_pay text,
  p_employment text,
  p_modality text,
  p_contact_type text,
  p_description text,
  p_requirements text
)
returns table (
  order_id uuid,
  access_code text,
  max_publications integer,
  used_publications integer,
  price numeric,
  duration_days integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.plans;
  o public.posting_orders;
begin
  select * into p
  from public.plans
  where id=p_plan_id and enabled=true and public_plan=true;

  if not found then
    raise exception 'Plan no válido o no disponible';
  end if;

  insert into public.posting_orders(
    plan_id,publisher_name,publisher_email,company,contact,
    price_snapshot,duration_days,max_publications,is_featured,is_urgent,
    payment_status,status
  )
  values(
    p.id,trim(p_publisher_name),nullif(trim(p_publisher_email),''),
    trim(p_company),trim(p_contact),
    p.price,p.duration_days,p.max_vacancies,p.featured,p.urgent,
    case when p.price=0 then 'waived' else 'pending' end,
    'pending'
  )
  returning * into o;

  insert into public.job_submissions(
    publisher_name,publisher_email,company,title,province,city,area,
    employment,modality,pay,requirements,description,contact,contact_type,
    plan_id,terms_accepted,order_id
  )
  values(
    o.publisher_name,o.publisher_email,o.company,trim(p_title),trim(p_province),
    trim(p_city),trim(p_area),nullif(trim(p_employment),''),
    coalesce(nullif(trim(p_modality),''),'Presencial'),
    coalesce(nullif(trim(p_pay),''),'Consultar al número'),
    trim(p_requirements),trim(p_description),o.contact,
    coalesce(nullif(trim(p_contact_type),''),'WhatsApp'),
    o.plan_id,true,o.id
  );

  update public.posting_orders
  set used_publications=1, updated_at=now()
  where id=o.id
  returning * into o;

  return query
  select o.id,o.access_code,o.max_publications,o.used_publications,
         o.price_snapshot,o.duration_days;
end;
$$;

-- 4) Usar otra publicación del MISMO paquete con el código del comprador.
create or replace function public.add_job_to_posting_order(
  p_access_code text,
  p_title text,
  p_area text,
  p_province text,
  p_city text,
  p_pay text,
  p_employment text,
  p_modality text,
  p_contact_type text,
  p_description text,
  p_requirements text
)
returns table (
  job_id bigint,
  used_publications integer,
  max_publications integer,
  remaining_publications integer,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.posting_orders;
  new_job_id bigint;
begin
  select * into o
  from public.posting_orders
  where access_code=trim(p_access_code)
  for update;

  if not found then
    raise exception 'Código de paquete incorrecto';
  end if;

  if o.status='cancelled' then
    raise exception 'Este paquete fue cancelado';
  end if;

  if o.expires_at is not null and o.expires_at <= now() then
    update public.posting_orders set status='expired', updated_at=now() where id=o.id;
    raise exception 'Este paquete ya venció';
  end if;

  if o.used_publications >= o.max_publications then
    raise exception 'Ya usaste todas las publicaciones de este paquete';
  end if;

  insert into public.job_submissions(
    publisher_name,publisher_email,company,title,province,city,area,
    employment,modality,pay,requirements,description,contact,contact_type,
    plan_id,terms_accepted,order_id
  )
  values(
    o.publisher_name,o.publisher_email,o.company,trim(p_title),trim(p_province),
    trim(p_city),trim(p_area),nullif(trim(p_employment),''),
    coalesce(nullif(trim(p_modality),''),'Presencial'),
    coalesce(nullif(trim(p_pay),''),'Consultar al número'),
    trim(p_requirements),trim(p_description),o.contact,
    coalesce(nullif(trim(p_contact_type),''),'WhatsApp'),
    o.plan_id,true,o.id
  )
  returning id into new_job_id;

  update public.posting_orders
  set used_publications=used_publications+1, updated_at=now()
  where id=o.id
  returning * into o;

  return query
  select new_job_id,o.used_publications,o.max_publications,
         o.max_publications-o.used_publications,o.expires_at;
end;
$$;

-- 5) Estado seguro del paquete usando su código.
create or replace function public.get_posting_order_status(p_access_code text)
returns table(
  plan_id text,
  company text,
  used_publications integer,
  max_publications integer,
  remaining_publications integer,
  payment_status text,
  status text,
  expires_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select o.plan_id,o.company,o.used_publications,o.max_publications,
         o.max_publications-o.used_publications,o.payment_status,
         case when o.expires_at is not null and o.expires_at<=now() then 'expired' else o.status end,
         o.expires_at
  from public.posting_orders o
  where o.access_code=trim(p_access_code);
$$;

-- 6) Cuando se aprueba una publicación, todo el paquete comparte la vigencia.
create or replace function public.prepare_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.posting_orders;
begin
  new.updated_at := now();

  if new.status='approved' and old.status is distinct from 'approved' then
    if new.order_id is not null then
      select * into o from public.posting_orders where id=new.order_id for update;
      if not found then raise exception 'Paquete de publicaciones no encontrado'; end if;

      if o.price_snapshot > 0 and o.payment_status not in ('verified','waived') then
        raise exception 'Primero confirma el pago del paquete.';
      end if;

      if o.expires_at is not null and o.expires_at<=now() then
        update public.posting_orders set status='expired',updated_at=now() where id=o.id;
        raise exception 'El paquete ya venció.';
      end if;

      if o.status='pending' then
        update public.posting_orders
        set status='active',starts_at=now(),
            expires_at=now()+make_interval(days=>duration_days),
            updated_at=now()
        where id=o.id
        returning * into o;
      end if;

      new.starts_at := coalesce(o.starts_at,now());
      new.expires_at := o.expires_at;
      new.payment_status := o.payment_status;
    else
      -- Compatibilidad con publicaciones antiguas/manuales.
      if new.price_snapshot > 0 and new.payment_status not in ('verified','waived') then
        raise exception 'Debes verificar o exonerar el pago antes de aprobar.';
      end if;
      new.starts_at := coalesce(new.starts_at,now());
      new.expires_at := now()+make_interval(days=>new.duration_days);
    end if;
  end if;

  if new.status='rejected' then
    new.starts_at := null;
    new.expires_at := null;
  end if;

  return new;
end;
$$;

-- 7) Renovar una prueba gratis a Básico: 2 publicaciones / 7 días.
create or replace function public.renew_free_order_to_basic(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.posting_orders;
  p public.plans;
begin
  if not public.is_chamba_admin() then raise exception 'No autorizado'; end if;

  select * into o from public.posting_orders where id=p_order_id for update;
  if not found then raise exception 'Paquete no encontrado'; end if;
  if o.plan_id<>'first_free' then raise exception 'No es una prueba gratis'; end if;
  if o.payment_status<>'verified' then raise exception 'Primero confirma el pago de $1'; end if;

  select * into p from public.plans where id='basic' and enabled=true;
  if not found then raise exception 'Plan Básico no disponible'; end if;

  update public.posting_orders
  set plan_id='basic',price_snapshot=p.price,duration_days=p.duration_days,
      max_publications=p.max_vacancies,is_featured=p.featured,is_urgent=p.urgent,
      status='active',starts_at=now(),expires_at=now()+make_interval(days=>p.duration_days),
      updated_at=now()
  where id=p_order_id
  returning * into o;

  update public.job_submissions
  set plan_id='basic',price_snapshot=p.price,duration_days=p.duration_days,
      max_vacancies=p.max_vacancies,is_featured=p.featured,is_urgent=p.urgent,
      payment_status='verified',status='approved',
      starts_at=o.starts_at,expires_at=o.expires_at,updated_at=now()
  where order_id=p_order_id and status<>'rejected';
end;
$$;

-- 8) Seguridad.
alter table public.posting_orders enable row level security;

drop policy if exists "admin_read_orders" on public.posting_orders;
create policy "admin_read_orders" on public.posting_orders
for select to authenticated using (public.is_chamba_admin());

drop policy if exists "admin_update_orders" on public.posting_orders;
create policy "admin_update_orders" on public.posting_orders
for update to authenticated using (public.is_chamba_admin()) with check (public.is_chamba_admin());

drop policy if exists "admin_delete_orders" on public.posting_orders;
create policy "admin_delete_orders" on public.posting_orders
for delete to authenticated using (public.is_chamba_admin());

grant execute on function public.create_posting_order_with_job(
  text,text,text,text,text,text,text,text,text,text,text,text,text,text,text
) to anon,authenticated;

grant execute on function public.add_job_to_posting_order(
  text,text,text,text,text,text,text,text,text,text,text
) to anon,authenticated;

grant execute on function public.get_posting_order_status(text) to anon,authenticated;
grant execute on function public.renew_free_order_to_basic(uuid) to authenticated;
