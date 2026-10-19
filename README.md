# Mobility Planet — Fleet Wash Control V1 (sorgenti)

Progetto Next.js + Supabase in italiano. **Non è ancora un servizio pubblicato**. Include autenticazione, segregazione dati per ruolo/sede/fornitore, richieste Mobility, workflow fornitore, convalida manuale e vista SQL per consuntivi.

## Avvio locale
1. Crea un progetto Supabase in regione UE e configura backup e MFA per gli amministratori.
2. Esegui `supabase/schema.sql` nel SQL Editor di un progetto **vuoto** (lo script crea tipi e tabelle, non è idempotente).
3. Disabilita le registrazioni pubbliche in Supabase Auth. Crea utenti di prova dalla console Auth; crea i relativi record in `profiles` con gli UUID Auth esatti.
4. Inserisci un fornitore in `suppliers`, abilitalo per Torino Caselle in `supplier_sites`, associa l'utente fornitore a `user_suppliers`, associa gli operatori a `user_sites`.
5. Copia `.env.example` in `.env.local` e valorizza URL e chiave **pubblica** Supabase. Non inserire la service-role key nel frontend.
6. Esegui `npm install` e `npm run dev`, quindi apri http://localhost:3000.
7. Per pubblicare, collega il repository a Vercel o hosting Next.js equivalente, imposta le variabili d'ambiente e configura dominio, HTTPS e monitoraggio.

## Esempio di provisioning SQL (sostituisci UUID reali)
```sql
insert into public.suppliers(name) values ('Fornitore Pilota');
-- Inserire profiles dopo aver creato gli utenti nella console Auth:
-- insert into public.profiles(id,display_name,role) values ('UUID_AUTH','Operatore Caselle','operator');
-- insert into public.user_sites(user_id,site_id) select 'UUID_AUTH',id from public.sites where name='Torino Caselle';
-- insert into public.supplier_sites(supplier_id,site_id) select sp.id,si.id from public.suppliers sp cross join public.sites si where sp.name='Fornitore Pilota' and si.name='Torino Caselle';
-- insert into public.user_suppliers(user_id,supplier_id) select 'UUID_FORNITORE',id from public.suppliers where name='Fornitore Pilota';
```

## Regole implementate
- Solo ruoli Mobility possono creare richieste.
- Il fornitore può prendere in carico, avviare e completare solo le richieste assegnate.
- Solo Mobility può convalidare o contestare; nessuna convalida automatica.
- Richiesta già aperta per stessa targa: bloccata.
- Nuova richiesta per targa già presente nelle ultime 24 ore: motivazione di almeno 10 caratteri obbligatoria.
- Tracciamento eventi append-only tramite funzioni SQL.
- La vista `monthly_reconciliation` include solo lavaggi convalidati.

## Limiti noti e lavori prima della produzione
- Questa è una **base di sviluppo / MVP di collaudo**, non un'app certificata pronta alla produzione.
- Riconciliazione fatture: schema dati e vista presenti, ma **mancano** UI di importazione fatture, abbinamento righe, chiusura periodo ed export Excel.
- Mancano pannello amministrativo per gestire utenti, tariffe e fornitori, allegati fotografici, test automatici, monitoraggio e procedure di disaster recovery.
- La UI non mostra in anticipo il dettaglio del precedente lavaggio: il backend impone comunque la motivazione quando necessaria.
- Migliorare la gestione della concorrenza dei tariffari e impedirne la sovrapposizione temporale; bloccare tariffe mancanti prima della chiusura economica.
- Aggiungere un test RLS con almeno due fornitori e due sedi, test di sessione e audit, rate limiting e policy di conservazione dati.
- Verificare configurazione SMTP, GDPR, accordi responsabile trattamento e procedure di autorizzazione per personale cessato.

## Funzioni aggiunte nella release 1.1
Dopo `schema.sql` eseguire `supabase/02_invoice_functions.sql`.
La UI include registro filtrabile, export CSV, coda convalide, dashboard KPI, consuntivo mensile, controllo delle tariffe mancanti e registrazione fatture con righe abbinate per ID.

### Limiti operativi da conoscere
- Per pubblicare serve un account Supabase e un hosting Next.js intestati a Mobility Planet: **nessuna istanza è stata creata automaticamente**.
- Gli account, le associazioni sedi-fornitori e i tariffari iniziali vanno caricati in Supabase SQL Editor da un amministratore. La V1 non include un pannello per il provisioning.
- L'importazione fatture accetta righe `UUID richiesta;importo`, non file PDF o XML FatturaPA. Il confronto degli importi per riga è visualizzabile esportando il consuntivo e confrontandolo con il dettaglio fattura; non è ancora presente una schermata automatica per gli scostamenti per riga.
- Prima dell'uso reale sono necessari test integrati con Supabase, controllo RLS, verifica backup e audit di sicurezza. Nessuna attestazione di test end-to-end o deployment viene fornita.
- `monthly_reconciliation` richiede tariffari configurati per sede/fornitore/tipo. I valori nulli indicano tariffa mancante.
