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
