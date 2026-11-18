-- NIOGEN | 0291_capi_lead_no_viavel.sql | 18/11/2026 — Claude Code (Agente de Tráfego)
-- Resumo: o evento LeadSubmitted passa a sair no degrau "viável" (a rua tem rede), e não mais na qualificada.
--   Por quê (Ricardo, 18/11): anúncio que leva ao WhatsApp só otimiza por "leads por mensagem", e a Meta conta esse lead pelo
--   evento LeadSubmitted (ou Purchase). Na qualificada ele saía ~2 vezes por semana — pouco demais para a Meta aprender; no
--   viável sai ~48 por semana. A qualificada continua medida, agora com o nome QualifiedLead (os dois trocam de lugar).
--   Nada muda no que vai à Meta além do nome do evento: ctwa_clid + telefone com hash (decisão de 06/11, não se reabre).
--   Sem backfill: a troca vale para fatos a partir do instante desta migration (degraus_desde). Evento antigo fica como está.
--   Conversa que já mandou QualifiedLead no viável antes da troca não manda outro QualifiedLead na qualificada (event_id
--   repetido, "on conflict do nothing"): perda de medida pequena e só na transição.
begin;

update public.config_regras
   set valor = valor
             || jsonb_build_object(
                  'degraus', jsonb_build_object(
                    'ViewContent',   'area_ok',
                    'LeadSubmitted', 'viavel',
                    'QualifiedLead', 'qualificada'),
                  'degraus_desde', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                  'degraus_antes', jsonb_build_object(
                    'ViewContent',   'area_ok',
                    'QualifiedLead', 'viavel',
                    'LeadSubmitted', 'qualificada')),
       descricao = descricao || ' 0291 (18/11): LeadSubmitted passou a sair no viável e QualifiedLead na qualificada '
                             || '(antes era o contrário; ver degraus_antes e degraus_desde).'
 where chave = 'meta_capi';

-- o cartão "A Meta recebeu": as colunas continuam dizendo o DEGRAU (viáveis, qualificadas), não o nome do evento,
-- então antes da troca viável = QualifiedLead e depois = LeadSubmitted (e o contrário para a qualificada).
create or replace view public.v_meta_capi_painel
with (security_invoker = true) as
with j as (select (now() at time zone 'America/Sao_Paulo')::date as hoje),
t as (select coalesce((valor ->> 'degraus_desde')::timestamptz, 'infinity'::timestamptz) as troca
        from public.config_regras where chave = 'meta_capi'),
e as (select e.*, (e.fato_em at time zone 'America/Sao_Paulo')::date as dia,
             case when e.evento = 'ViewContent' then 'cidade'
                  when e.evento = 'Purchase' then 'venda'
                  when (e.evento = 'QualifiedLead') = (e.fato_em < t.troca) then 'viavel'
                  else 'qualificada' end as degrau
        from public.meta_eventos e cross join t)
select
  (select count(*) from e, j where e.dia = j.hoje and e.status = 'enviado' and e.degrau = 'cidade')::int        as cidade_hoje,
  (select count(*) from e, j where e.dia = j.hoje and e.status = 'enviado' and e.degrau = 'viavel')::int        as viaveis_hoje,
  (select count(*) from e, j where e.dia = j.hoje and e.status = 'enviado' and e.degrau = 'qualificada')::int   as qualificadas_hoje,
  (select count(*) from e, j where e.dia = j.hoje and e.status = 'enviado' and e.degrau = 'venda')::int         as vendas_hoje,
  (select count(*) from e, j where e.dia = j.hoje and e.status = 'enviado')::int                                as enviados_hoje,
  (select count(*) from e, j where e.dia = j.hoje and e.status = 'sem_clique')::int                             as sem_clique_hoje,
  (select count(*) from e, j where e.dia = j.hoje and e.status = 'erro')::int                                   as erros_hoje,
  (select count(*) from e, j where e.dia > j.hoje - 7 and e.status = 'enviado' and e.degrau = 'cidade')::int      as cidade_7d,
  (select count(*) from e, j where e.dia > j.hoje - 7 and e.status = 'enviado' and e.degrau = 'viavel')::int      as viaveis_7d,
  (select count(*) from e, j where e.dia > j.hoje - 7 and e.status = 'enviado' and e.degrau = 'qualificada')::int as qualificadas_7d,
  (select count(*) from e, j where e.dia > j.hoje - 7 and e.status = 'enviado' and e.degrau = 'venda')::int       as vendas_7d,
  (select count(*) from e, j where e.dia > j.hoje - 7 and e.status = 'enviado')::int                                as enviados_7d,
  (select count(*) from e, j where e.dia > j.hoje - 7 and e.status = 'sem_clique')::int                             as sem_clique_7d,
  (select count(*) from e, j where e.dia > j.hoje - 7 and e.status = 'erro')::int                                   as erros_7d,
  (select count(*) from e where e.status in ('pendente', 'erro'))::int                                              as na_fila,
  (select max(e.enviado_em) from e)                                                                                 as ultimo_envio,
  (select count(*) from e where e.status in ('pendente', 'erro') and e.criado_em < now() - interval '1 hour')::int   as atrasados,
  (select valor ->> 'dataset_id' from public.config_regras where chave = 'meta_capi')                               as dataset_id;
comment on view public.v_meta_capi_painel is
  'Cartão "A Meta recebeu" (Meta Ads › Desempenho): hoje e 7 dias, por DEGRAU (cidade, viável, qualificada, venda), mais fila, '
  'atraso e último envio. 0186; 0291: o degrau sai do evento conforme config_regras.meta_capi.degraus_desde '
  '(antes: viável = QualifiedLead; depois: viável = LeadSubmitted).';
grant select on public.v_meta_capi_painel to authenticated;

commit;
