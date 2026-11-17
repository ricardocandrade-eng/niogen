-- NIOGEN | supabase/migrations/0258_sombra_conferencia.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Passo 4 (porta única), 2ª parte (4b) — Ricardo, 17/11: "Sim, os dois".
-- SÓ LEITURA. A conferência da sombra: para cada lead, o que a situação MANDA (config_situacao) contra o que ESTÁ de fato no
-- espelho do Chatwoot (mari_conversas: status, pessoa, time, etiquetas). Cada linha de v_lead_situacao_divergencias é um ponto
-- que o passo 5 (virar a chave) vai corrigir — ou um ajuste na própria tabela de situações, se o Ricardo decidir que o real está certo.
--   config_situacao ganha: cw_status (status aceitos no Chatwoot; nulo = qualquer) e dono ('nenhum' | 'time' | 'qualquer').
--   Regras gerais, valem em toda situação: Não contatar ⇔ etiqueta nao-contatar; em Saída/Instalada/Cliente Nio, sem handoff-*.
begin;

alter table public.config_situacao add column if not exists cw_status text[];
alter table public.config_situacao add column if not exists dono text not null default 'qualquer';

update public.config_situacao s set cw_status = x.cw, dono = x.dono
  from (values
    ('mari_atendendo',        array['open'],                 'nenhum'),
    ('time_agora',            array['open'],                 'time'),
    ('time_esperando',        array['resolved'],             'time'),
    ('em_espera',             array['snoozed'],              'qualquer'),
    ('qualificado_credito',   null::text[],                  'qualquer'),
    ('qualificado_biometria', null::text[],                  'qualquer'),
    ('qualificado_os',        array['open'],                 'time'),
    ('instalacao_agendar',    array['open'],                 'time'),
    ('instalacao_aguardando', null::text[],                  'qualquer'),
    ('instalacao_pendencia',  null::text[],                  'qualquer'),
    ('instalada',             array['resolved'],             'nenhum'),
    ('saida_pode_voltar',     array['resolved', 'snoozed'],  'nenhum'),
    ('saida_definitiva',      array['resolved', 'snoozed'],  'nenhum'),
    ('nao_contatar',          array['resolved', 'snoozed'],  'nenhum'),
    ('cliente_nio',           array['resolved', 'snoozed'],  'nenhum')
  ) as x(codigo, cw, dono)
 where s.codigo = x.codigo;

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
