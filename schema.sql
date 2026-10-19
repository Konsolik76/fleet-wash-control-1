-- Fleet Wash Control V1 - eseguire una sola volta nel SQL Editor Supabase
create extension if not exists pgcrypto;
create type public.app_role as enum ('admin','manager','operator','supplier');
create type public.wash_kind as enum ('fast','completo');
create type public.wash_status as enum ('richiesto','in_carico','in_lavorazione','completato','convalidato','contestato','annullato');
create table public.sites(id uuid primary key default gen_random_uuid(),name text not null unique);
create table public.suppliers(id uuid primary key default gen_random_uuid(),name text not null unique,vat_number text);
create table public.profiles(id uuid primary key references auth.users(id) on delete cascade,display_name text not null,role public.app_role not null);
create table public.user_sites(user_id uuid not null references public.profiles(id) on delete cascade,site_id uuid not null references public.sites(id) on delete cascade,primary key(user_id,site_id));
create table public.user_suppliers(user_id uuid not null references public.profiles(id) on delete cascade,supplier_id uuid not null references public.suppliers(id) on delete cascade,primary key(user_id,supplier_id));
create table public.supplier_sites(supplier_id uuid not null references public.suppliers(id) on delete cascade,site_id uuid not null references public.sites(id) on delete cascade,primary key(supplier_id,site_id));
create table public.wash_requests(id uuid primary key default gen_random_uuid(),plate text not null,site_id uuid not null references public.sites(id),supplier_id uuid not null references public.suppliers(id),reason text not null,wash_type public.wash_kind not null,status public.wash_status not null default 'richiesto',repeat_justification text,note text,created_by uuid not null references auth.users(id),created_at timestamptz not null default now(),accepted_at timestamptz,started_at timestamptz,completed_at timestamptz,validated_at timestamptz,validated_by uuid references auth.users(id),dispute_reason text,check (plate ~ '^[A-Z0-9]{5,8}$'),check (length(trim(reason))>0));
create index wash_plate_time on public.wash_requests(plate,created_at desc);
create index wash_supplier_status on public.wash_requests(supplier_id,status);
create table public.wash_events(id bigint generated always as identity primary key,request_id uuid not null references public.wash_requests(id),actor_id uuid not null references auth.users(id),event text not null,reason text,created_at timestamptz not null default now());
create table public.tariffs(id uuid primary key default gen_random_uuid(),supplier_id uuid not null references public.suppliers(id),site_id uuid not null references public.sites(id),wash_type public.wash_kind not null,unit_price numeric(12,2) not null check(unit_price>=0),valid_from date not null,valid_to date,check(valid_to is null or valid_to>=valid_from));
create table public.invoices(id uuid primary key default gen_random_uuid(),supplier_id uuid not null references public.suppliers(id),period_month date not null,invoice_number text not null,net_amount numeric(12,2) not null,created_at timestamptz not null default now(),unique(supplier_id,invoice_number));
create table public.invoice_lines(id uuid primary key default gen_random_uuid(),invoice_id uuid not null references public.invoices(id),request_id uuid references public.wash_requests(id),claimed_amount numeric(12,2) not null,external_reference text);

create function public.my_role() returns public.app_role language sql stable security definer set search_path='' as $$select role from public.profiles where id=(select auth.uid())$$;
create function public.can_site(p_site uuid) returns boolean language sql stable security definer set search_path='' as $$select public.my_role()='admin' or exists(select 1 from public.user_sites where user_id=(select auth.uid()) and site_id=p_site)$$;
create function public.can_supplier(p_supplier uuid) returns boolean language sql stable security definer set search_path='' as $$select public.my_role()='admin' or exists(select 1 from public.user_suppliers where user_id=(select auth.uid()) and supplier_id=p_supplier)$$;

alter table public.sites enable row level security;
alter table public.suppliers enable row level security;
alter table public.profiles enable row level security;
alter table public.user_sites enable row level security;
alter table public.user_suppliers enable row level security;
alter table public.supplier_sites enable row level security;
alter table public.wash_requests enable row level security;
alter table public.wash_events enable row level security;
alter table public.tariffs enable row level security;
alter table public.invoices enable row level security;
alter table public.invoice_lines enable row level security;
create policy profiles_self on public.profiles for select to authenticated using(id=(select auth.uid()));
create policy sites_visible on public.sites for select to authenticated using(public.can_site(id) or exists(select 1 from public.supplier_sites ss where ss.site_id=sites.id and public.can_supplier(ss.supplier_id)));
create policy suppliers_visible on public.suppliers for select to authenticated using(public.can_supplier(id) or (public.my_role() in ('operator','manager') and exists(select 1 from public.supplier_sites ss where ss.supplier_id=suppliers.id and public.can_site(ss.site_id))));
create policy supplier_sites_visible on public.supplier_sites for select to authenticated using(public.can_supplier(supplier_id) or public.can_site(site_id));
create policy requests_visible on public.wash_requests for select to authenticated using((public.my_role() in ('operator','manager','admin') and public.can_site(site_id)) or (public.my_role()='supplier' and public.can_supplier(supplier_id)));
create policy events_visible on public.wash_events for select to authenticated using(exists(select 1 from public.wash_requests wr where wr.id=request_id));
create policy tariffs_visible on public.tariffs for select to authenticated using(public.my_role() in ('admin','manager') and public.can_site(site_id));
create policy invoices_visible on public.invoices for select to authenticated using(public.my_role() in ('admin','manager') and public.can_supplier(supplier_id));
create policy invoice_lines_visible on public.invoice_lines for select to authenticated using(exists(select 1 from public.invoices i where i.id=invoice_id));
-- Nessuna policy INSERT/UPDATE/DELETE diretta: mutazioni solo via funzioni controllate.
create or replace function public.create_wash_request(p_plate text,p_site_id uuid,p_supplier_id uuid,p_reason text,p_wash_type public.wash_kind,p_repeat_justification text default null,p_note text default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;v_plate text;v_repeat boolean;
begin
 if public.my_role() not in ('operator','manager','admin') or not public.can_site(p_site_id) then raise exception 'Operazione non autorizzata';end if;
 if not exists(select 1 from public.supplier_sites where supplier_id=p_supplier_id and site_id=p_site_id) then raise exception 'Fornitore non abilitato per questo DMS';end if;
 v_plate:=upper(regexp_replace(coalesce(p_plate,''),'\s','','g'));
 if v_plate !~ '^[A-Z0-9]{5,8}$' then raise exception 'Targa non valida';end if;
 if p_reason not in ('Rientro da noleggio','Sostituzione','Breakdown / guasto','Rientro manutenzione','Trasferimento flotta','Preparazione consegna','Sporco eccezionale','Altro') then raise exception 'Causale non valida';end if;
 if p_reason='Altro' and length(trim(coalesce(p_note,'')))=0 then raise exception 'Specificare causale Altro';end if;
 -- Serializza le richieste della stessa targa anche fra operatori concorrenti.
 perform pg_advisory_xact_lock(hashtextextended(v_plate,0));
 if exists(select 1 from public.wash_requests where plate=v_plate and status in ('richiesto','in_carico','in_lavorazione','completato')) then raise exception 'Esiste già una richiesta aperta per questa targa';end if;
 select exists(select 1 from public.wash_requests where plate=v_plate and created_at>=now()-interval '24 hours' and status not in ('annullato')) into v_repeat;
 if v_repeat and length(trim(coalesce(p_repeat_justification,'')))<10 then raise exception 'Lavaggio ripetuto nelle 24 ore: inserire motivazione di almeno 10 caratteri';end if;
 insert into public.wash_requests(plate,site_id,supplier_id,reason,wash_type,repeat_justification,note,created_by) values(v_plate,p_site_id,p_supplier_id,p_reason,p_wash_type,nullif(trim(p_repeat_justification),''),p_note,auth.uid()) returning id into v_id;
 insert into public.wash_events(request_id,actor_id,event,reason) values(v_id,auth.uid(),'creazione',case when v_repeat then p_repeat_justification else null end);
 return v_id;
end $$;
create or replace function public.transition_wash_request(p_id uuid,p_action text,p_reason text default null)
returns void language plpgsql security definer set search_path='' as $$
declare r public.wash_requests%rowtype;v_role public.app_role;v_next public.wash_status;
begin
 select * into r from public.wash_requests where id=p_id for update;
 if not found then raise exception 'Richiesta non trovata';end if;
 v_role:=public.my_role();
 if p_action in ('accept','start','complete') then
  if v_role<>'supplier' or not public.can_supplier(r.supplier_id) then raise exception 'Operazione riservata al fornitore assegnato';end if;
  if p_action='accept' and r.status='richiesto' then v_next:='in_carico';
  elsif p_action='start' and r.status='in_carico' then v_next:='in_lavorazione';
  elsif p_action='complete' and r.status='in_lavorazione' then v_next:='completato';
  else raise exception 'Transizione non consentita';end if;
 elsif p_action in ('validate','dispute') then
  if v_role not in ('operator','manager','admin') or not public.can_site(r.site_id) then raise exception 'Convalida riservata a Mobility Planet';end if;
  if r.status<>'completato' then raise exception 'La richiesta non è completata';end if;
  if p_action='dispute' and length(trim(coalesce(p_reason,'')))<5 then raise exception 'Motivo contestazione obbligatorio';end if;
  v_next:=case when p_action='validate' then 'convalidato'::public.wash_status else 'contestato'::public.wash_status end;
 else raise exception 'Azione non riconosciuta';end if;
 update public.wash_requests set status=v_next,accepted_at=case when p_action='accept' then now() else accepted_at end,started_at=case when p_action='start' then now() else started_at end,completed_at=case when p_action='complete' then now() else completed_at end,validated_at=case when p_action='validate' then now() else validated_at end,validated_by=case when p_action='validate' then auth.uid() else validated_by end,dispute_reason=case when p_action='dispute' then p_reason else dispute_reason end where id=p_id;
 insert into public.wash_events(request_id,actor_id,event,reason) values(p_id,auth.uid(),p_action,p_reason);
end $$;
revoke all on function public.create_wash_request(text,uuid,uuid,text,public.wash_kind,text,text) from public;
revoke all on function public.transition_wash_request(uuid,text,text) from public;
grant execute on function public.create_wash_request(text,uuid,uuid,text,public.wash_kind,text,text) to authenticated;
grant execute on function public.transition_wash_request(uuid,text,text) to authenticated;
-- View per riconciliazione: accesso da amministrazione con query server-side autorizzate, non esporre pubblicamente.
create view public.monthly_reconciliation with (security_invoker=true) as
select w.id,w.plate,w.site_id,w.supplier_id,w.completed_at::date as service_date,date_trunc('month',w.completed_at)::date as period_month,w.wash_type,w.reason,t.unit_price
from public.wash_requests w
left join lateral(select unit_price from public.tariffs t where t.supplier_id=w.supplier_id and t.site_id=w.site_id and t.wash_type=w.wash_type and t.valid_from<=w.completed_at::date and (t.valid_to is null or t.valid_to>=w.completed_at::date) order by t.valid_from desc limit 1)t on true
where w.status='convalidato';
revoke all on public.monthly_reconciliation from anon;
grant select on public.monthly_reconciliation to authenticated;
-- Seed sedi (fornitori, utenti e abilitazioni vengono inseriti manualmente da un amministratore)
insert into public.sites(name) values('Torino Caselle'),('Torino Porta Susa'),('Nichelino'),('Torino Lingotto'),('Bergamo Aeroporto'),('Milano Centrale'),('Verona'),('Venezia Aeroporto'),('Bologna Aeroporto'),('Bologna Stazione'),('Firenze Aeroporto'),('Parma'),('Bolzano Stazione'),('Olbia') on conflict do nothing;
