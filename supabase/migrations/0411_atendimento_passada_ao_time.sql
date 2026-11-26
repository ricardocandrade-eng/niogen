-- NIOGEN | supabase/migrations/0411_atendimento_passada_ao_time.sql | 25/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 25/11 (sobre a pendência "a resposta do consultor no Chatwoot volta ao NIOGEN": "Tenho evitado responder pelo Chatwoot" →
-- "Sim, corrige"). A medição mostrou que das 14 "passadas ao consultor sem resposta do time", 13 eram encerramentos da Mari
-- (fora da área, sem cobertura, recusou, teste): handoff_em também é gravado quando ela encerra. O bloco "Atendimento dos leads"
-- (meta_ads_atendimento, 0406) passa a contar como passada ao consultor só a que pede uma pessoa: dados completos, pedido de humano,
-- objeção, urgência, vários decisores, interesse caindo. O resto da função não muda. Sem pendência no Chatwoot.
-- Regra 20: nenhum estado novo; só a conta de uma tela de leitura; fonte única (mesma função para admin, prévia e agência).
begin;

create or replace function public.meta_ads_atendimento(p_de date default null, p_ate date default null, p_agencia boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb; v_ag boolean;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') and not public.sou_agencia() then
    return null;
  end if;
  v_ag := public._agencia_recorte(p_agencia);
  with atrib as (
    select a.conversa_id, a.ad_id, a.campanha_id from public.v_mari_conversa_anuncio a
     where a.ad_id is not null and (not v_ag or a.campanha_id in (select public.agencia_campanhas()))
  ), c as (
    select c.id, coalesce(c.funil_destino, 'em_andamento') as destino, a.ad_id, a.campanha_id,
           -- 0411: só conta como "passada ao consultor" a passagem que pede uma pessoa; encerramento da Mari (fora da área, sem
           -- cobertura, recusou, já é cliente) também grava handoff_em, mas não espera resposta do time
           case when c.handoff_motivo in ('dados_completos', 'pedido_humano', 'objecao', 'urgencia_alta', 'multiplos_decisores', 'interesse_caindo')
                then c.handoff_em end as handoff_em
      from public.mari_conversas c left join atrib a on a.conversa_id = c.id
     where c.origem = 'meta_ads' and c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
       and (not v_ag or a.conversa_id is not null)
       and (p_de is null or (c.created_at at time zone 'America/Sao_Paulo')::date >= p_de)
       and (p_ate is null or (c.created_at at time zone 'America/Sao_Paulo')::date <= p_ate)
  ), t as (
    select c.*, x.l1, x.lu, x.ru,
           (select min(t.created_at) from public.mari_turnos t where t.conversa_id = c.id and t.papel in ('mari', 'humano') and t.created_at >= x.l1) as r1,
           (select min(t.created_at) from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano' and t.created_at >= c.handoff_em) as h1
      from c cross join lateral (
        select min(t.created_at) filter (where t.papel = 'lead') as l1, max(t.created_at) filter (where t.papel = 'lead') as lu,
               max(t.created_at) filter (where t.papel in ('mari', 'humano')) as ru
          from public.mari_turnos t where t.conversa_id = c.id) x
  ), m as (
    select t.*, extract(epoch from t.r1 - t.l1) as s1, extract(epoch from t.h1 - t.handoff_em) / 60 as hm,
           (t.lu is not null and t.lu > coalesce(t.ru, '-infinity') and t.lu < now() - interval '15 minutes') as ultima_do_cliente
      from t
  ), g as (
    select grouping(m.campanha_id, m.ad_id) as nivel, m.campanha_id, m.ad_id,
           count(*) filter (where m.l1 is not null)::int as conversas,
           count(*) filter (where m.l1 is not null and m.r1 is not null)::int as respondidas,
           count(*) filter (where m.l1 is not null and m.r1 is null)::int as sem_resposta,
           round(percentile_cont(0.5) within group (order by m.s1)::numeric, 1) as resp_mediana_s,
           round(percentile_cont(0.95) within group (order by m.s1)::numeric, 1) as resp_p95_s,
           round(max(m.s1)::numeric, 1) as resp_pior_s,
           count(*) filter (where m.s1 > 60)::int as resp_acima_1min,
           count(*) filter (where m.handoff_em is not null)::int as passadas_consultor,
           count(*) filter (where m.handoff_em is not null and m.h1 is not null)::int as consultor_medidas,
           round(percentile_cont(0.5) within group (order by m.hm)::numeric, 1) as consultor_mediana_min,
           round(max(m.hm)::numeric, 1) as consultor_pior_min,
           count(*) filter (where m.ultima_do_cliente and m.destino = 'em_andamento')::int as paradas,
           count(*) filter (where m.ultima_do_cliente and m.destino <> 'em_andamento')::int as encerradas_sem_resposta
      from m group by grouping sets ((m.campanha_id, m.ad_id), ())
  )
  select jsonb_build_object(
    'total', (select to_jsonb(g) - 'nivel' - 'campanha_id' - 'ad_id' from g where g.nivel = 3),
    'linhas', coalesce((select jsonb_agg(to_jsonb(g) - 'nivel' || jsonb_build_object('ad_nome', a.ad_nome, 'campanha_nome', d.campanha_nome)
                                         order by g.conversas desc, a.ad_nome)
                          from g left join public.meta_ads_anuncios a on a.ad_id = g.ad_id
                                 left join public.meta_ads_campanhas_dono d on d.campanha_id = g.campanha_id
                         where g.nivel = 0), '[]'::jsonb),
    'recorte', v_ag
  ) into r;
  return r;
end $$;
revoke all on function public.meta_ads_atendimento(date, date, boolean) from public, anon;
grant execute on function public.meta_ads_atendimento(date, date, boolean) to authenticated;

commit;
