-- NIOGEN | supabase/migrations/0260_sombra_sem_testes.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Passo 4b: a conferência da sombra (0258) contava conversas de TESTE ou duplicadas (15 abertas na produção, entre elas a conversa 1).
-- Elas ficam fora da conta (config_lead: "teste_duplicada — fora da conta") e agora também fora da conferência. Só leitura.
begin;

create or replace view public.v_lead_situacao_divergencias with (security_invoker = true) as
with b as (
  select ls.lead_id, ls.conversa_id, ls.venda_id, ls.nome, ls.situacao, ls.situacao_numero, ls.situacao_nome, ls.sem_mensagens,
         s.cw_status, s.dono,
         coalesce(c.chatwoot_status, 'open') as cw, c.chatwoot_agente as pessoa, c.chatwoot_time as time_cw,
         coalesce(c.chatwoot_etiquetas, '{}'::text[]) as etq, coalesce(c.nao_contatar, false) as nc,
         c.ultima_msg_lead_at, c.chatwoot_conversation_id
    from public.v_lead_situacao ls
    join public.mari_conversas c on c.id = ls.conversa_id
    left join public.config_situacao s on s.codigo = ls.situacao
   where c.canal = 'whatsapp' and c.chatwoot_conversation_id is not null and ls.situacao is not null
     and ls.destino <> 'teste_duplicada'   -- 0260: teste ou duplicada fica fora da conta (e fora da conferência)
)
select lead_id, conversa_id, venda_id, chatwoot_conversation_id, nome, situacao_numero, situacao_nome, d.item, d.esperado, d.de_fato
  from b
 cross join lateral (values
   ('Chatwoot aberta/resolvida',
      case when cw_status is not null and not (cw = any (cw_status)) then array_to_string(cw_status, ' ou ') end, cw),
   ('dono',
      case when dono = 'nenhum' and (pessoa is not null or time_cw is not null) then 'sem dono'
           when dono = 'time' and pessoa is null and time_cw is null then 'com o time' end,
      case when pessoa is not null then 'pessoa: ' || pessoa when time_cw is not null then 'time: ' || time_cw else 'sem dono' end),
   ('etiqueta nao-contatar',
      case when nc <> ('nao-contatar' = any (etq)) then case when nc then 'com a etiqueta' else 'sem a etiqueta' end end,
      case when 'nao-contatar' = any (etq) then 'com a etiqueta' else 'sem a etiqueta' end),
   ('etiqueta handoff',
      case when situacao in ('instalada', 'saida_pode_voltar', 'saida_definitiva', 'nao_contatar', 'cliente_nio')
                and etq && array['handoff-venda', 'handoff-humano'] then 'sem handoff-venda/humano' end,
      array_to_string(array(select e from unnest(etq) e where e like 'handoff%'), ', '))
 ) as d(item, esperado, de_fato)
 where d.esperado is not null;
grant select on public.v_lead_situacao_divergencias to authenticated;

commit;
