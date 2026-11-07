-- NIOGEN | supabase/migrations/0060_meta_ads_qualificada_dados_completos.sql | 07/11/2026 — Claude Code (pedido do Ricardo: "pode ajustar")
-- Por quê: a tela Meta Ads contava como "qualificada" todo handoff (inclusive interesse_caindo e já cliente), enquanto a tela
-- Mari e o retrato do Agente de Tráfego (0059) contam só o handoff com dados completos — 07/11: tela 2 × arquivo 1.
-- Agora os três usam o mesmo critério: qualificada = handoff_motivo 'dados_completos' (a Mari criou a venda em 0 · Qualificado).
-- Só a coluna qualificadas da v_meta_ads_dia muda; nomes, ordem e tipos das colunas iguais (create or replace).

create or replace view public.v_meta_ads_dia
with (security_invoker = true) as
with
meta as (
  select dia, sum(gasto) as gasto, sum(impressoes)::int as impressoes, sum(cliques)::int as cliques,
         sum(conversas)::int as conversas_meta, max(atualizado_em) as atualizado_em
    from public.meta_ads_diario group by dia
),
mari as (
  select (created_at at time zone 'America/Sao_Paulo')::date as dia,
         count(*)::int                                                         as conversas_mari,
         count(*) filter (where cep is not null)::int                          as com_cep,
         count(*) filter (where elegibilidade = 'fora_area' or dentro_area is false)::int as fora_area,
         count(*) filter (where handoff_motivo = 'dados_completos')::int        as qualificadas
    from public.mari_conversas
   where origem = 'meta_ads' and canal = 'whatsapp'
   group by 1
),
venda as (
  select (criado_em at time zone 'America/Sao_Paulo')::date as dia,
         count(*) filter (where status <> 'saida')::int                         as vendas,
         count(*) filter (where biometria_status = 'aprovada')::int             as vendas_biometria,
         coalesce(sum(comissao_prevista) filter (where biometria_status = 'aprovada'), 0) as comissao_prevista
    from public.vendas
   where origem = 'meta_ads'
   group by 1
),
dias as (select dia from meta union select dia from mari union select dia from venda)
select d.dia,
       coalesce(m.gasto, 0)              as gasto,
       coalesce(m.impressoes, 0)         as impressoes,
       coalesce(m.cliques, 0)            as cliques,
       coalesce(m.conversas_meta, 0)     as conversas_meta,
       coalesce(c.conversas_mari, 0)     as conversas_mari,
       coalesce(c.com_cep, 0)            as com_cep,
       coalesce(c.fora_area, 0)          as fora_area,
       coalesce(c.qualificadas, 0)       as qualificadas,
       coalesce(v.vendas, 0)             as vendas,
       coalesce(v.vendas_biometria, 0)   as vendas_biometria,
       coalesce(v.comissao_prevista, 0)  as comissao_prevista,
       m.atualizado_em
  from dias d
  left join meta  m on m.dia = d.dia
  left join mari  c on c.dia = d.dia
  left join venda v on v.dia = d.dia;

comment on view public.v_meta_ads_dia is
  'Meta Ads por dia: gasto/conversas da Meta (meta_ads_diario) ao lado das conversas da Mari com origem meta_ads (com CEP, fora da área, qualificadas = handoff dados_completos) e das vendas meta_ads (biometria aprovada). security_invoker: cada perfil vê o que a RLS das tabelas deixa. 0034, critério de qualificada em 0060.';

grant select on public.v_meta_ads_dia to authenticated;
