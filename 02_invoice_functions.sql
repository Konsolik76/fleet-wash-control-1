-- Eseguire DOPO schema.sql. Richiede progetto Supabase PostgreSQL.
-- Solo amministratori e manager possono registrare fatture, con controllo delle sedi autorizzate.
create or replace function public.register_supplier_invoice(
 p_supplier_id uuid,p_period_month date,p_invoice_number text,p_net_amount numeric,p_lines jsonb
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_line jsonb; v_req public.wash_requests%rowtype; v_count int:=0; v_sum numeric:=0;
begin
 if public.my_role() not in ('admin','manager') then raise exception 'Operazione non autorizzata'; end if;
 if p_period_month<>date_trunc('month',p_period_month)::date or length(trim(coalesce(p_invoice_number,'')))<1 or p_net_amount<0 then raise exception 'Dati fattura non validi'; end if;
 if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)<1 or jsonb_array_length(p_lines)>3000 then raise exception 'Righe fattura non valide';end if;
 for v_line in select value from jsonb_array_elements(p_lines) loop
   if (v_line->>'request_id') is null or (v_line->>'claimed_amount') is null then raise exception 'ID e importo obbligatori';end if;
   select * into v_req from public.wash_requests where id=(v_line->>'request_id')::uuid;
   if not found or v_req.supplier_id<>p_supplier_id or v_req.status<>'convalidato' or date_trunc('month',v_req.completed_at)::date<>p_period_month then raise exception 'Riga non riconciliabile: %',v_line->>'request_id';end if;
   if not public.can_site(v_req.site_id) then raise exception 'Sede non autorizzata';end if;
   if (v_line->>'claimed_amount')::numeric<0 then raise exception 'Importo negativo';end if;
   v_count:=v_count+1;v_sum:=v_sum+(v_line->>'claimed_amount')::numeric;
 end loop;
 if abs(v_sum-p_net_amount)>0.01 then raise exception 'Somma righe diversa da imponibile fattura';end if;
 if (select count(distinct value->>'request_id') from jsonb_array_elements(p_lines))<>v_count then raise exception 'Righe duplicate nella stessa fattura';end if;
 if exists(select 1 from public.invoice_lines il join public.invoices i on i.id=il.invoice_id where i.supplier_id=p_supplier_id and il.request_id in (select (value->>'request_id')::uuid from jsonb_array_elements(p_lines))) then raise exception 'Richiesta già fatturata';end if;
 insert into public.invoices(supplier_id,period_month,invoice_number,net_amount) values(p_supplier_id,p_period_month,p_invoice_number,p_net_amount) returning id into v_id;
 for v_line in select value from jsonb_array_elements(p_lines) loop
   insert into public.invoice_lines(invoice_id,request_id,claimed_amount) values(v_id,(v_line->>'request_id')::uuid,(v_line->>'claimed_amount')::numeric);
 end loop;
 return v_id;
end $$;
revoke all on function public.register_supplier_invoice(uuid,date,text,numeric,jsonb) from public;
grant execute on function public.register_supplier_invoice(uuid,date,text,numeric,jsonb) to authenticated;
create unique index if not exists invoice_line_request_once on public.invoice_lines(request_id) where request_id is not null;
-- Impedisce a manager di leggere fatture di sedi non autorizzate tramite la policy originaria.
drop policy if exists invoices_visible on public.invoices;
create policy invoices_visible on public.invoices for select to authenticated using (
 public.my_role()='admin' or (public.my_role()='manager' and exists (
 select 1 from public.invoice_lines il join public.wash_requests w on w.id=il.request_id
 where il.invoice_id=invoices.id and public.can_site(w.site_id)
 ))
);
-- I profili sono gestiti da un amministratore nella console Supabase, non dal client.
