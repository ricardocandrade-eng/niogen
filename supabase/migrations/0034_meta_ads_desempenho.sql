-- NIOGEN | supabase/migrations/0034_meta_ads_desempenho.sql | 06/11/2026 — Claude Code (pedido do Ricardo, depois do prompt 22)
-- Desempenho da Meta Ads dentro do NIOGEN (aba "Desempenho" da tela Meta Ads, mockup MetaAds.dc.html).
-- A campanha 1 de JF está ATIVA desde 06/11 10h59; até aqui a tela só mostrava os bairros (DFV) e não lia nada da Meta.
--   1. meta_ads_anuncios — 1 linha por anúncio da CA act_764071346694892: nomes, conjunto, campanha, status efetivo.
--   2. meta_ads_diario   — 1 linha por anúncio × dia (fuso da conta = America/Sao_Paulo): gasto, impressões, alcance,
--                          cliques, conversas iniciadas (onsite_conversion.messaging_conversation_started_7d) e o `actions` cru.
--   3. meta_ads_gravar(p_insights, p_anuncios) — chamada só pelo n8n (workflow meta_ads_coleta, service role):
--      recebe o `data` cru da Graph API (/insights level=ad time_increment=1 e /ads) e faz upsert. Idempotente.
--   4. v_meta_ads_dia — por dia: o que a Meta diz (gasto, conversas) ao lado do que a Mari e o NIOGEN dizem
--      (conversas com origem meta_ads, com CEP, fora da área, qualificadas = handoff, vendas e vendas com biometria aprovada).
-- Só leitura para o front (usuário logado). Nada aqui pausa, ativa ou muda verba — isso segue sendo ordem do Ricardo.
-- Atribuição por anúncio (ad_id no referral) ainda não existe: Mari e vendas entram só no total do dia.

-- ─────────────────────────────── 1. anúncios ───────────────────────────────
create table if not exists public.meta_ads_anuncios (
  ad_id             text primary key,
  ad_nome           text,
  adset_id          text,
  adset_nome        text,
  campanha_id       text,
  campanha_nome     text,
  status_efetivo    text,            -- ACTIVE, PAUSED, IN_PROCESS, WITH_ISSUES, CAMPAIGN_PAUSED, ADSET_PAUSED…
  atualizado_em     timestamptz not null default now()
);

-- ─────────────────────────────── 2. diário ───────────────────────────────
create table if not exists public.meta_ads_diario (
  dia               date not null,
  ad_id             text not null,
  ad_nome           text,
  adset_id          text,
  adset_nome        text,
  campanha_id       text,
  campanha_nome     text,
  gasto             numeric(12, 2) not null default 0,
  impressoes        int not null default 0,
  alcance           int not null default 0,
  cliques           int not null default 0,
  conversas         int not null default 0,   -- conversas iniciadas no WhatsApp, pela Meta (janela de 7 d)
  acoes             jsonb,                    -- `actions` cru da Graph API, para auditoria
  atualizado_em     timestamptz not null default now(),
  primary key (dia, ad_id)
);
create index if not exists meta_ads_diario_campanha_idx on public.meta_ads_diario (campanha_id, dia);

comment on table public.meta_ads_diario is
  'Insights da Meta por anúncio e dia (fuso da conta, America/Sao_Paulo). Gravado só pelo n8n (meta_ads_coleta) via meta_ads_gravar. 0034.';
comment on column public.meta_ads_diario.conversas is
  'onsite_conversion.messaging_conversation_started_7d — conversas iniciadas no WhatsApp contadas pela Meta.';

alter table public.meta_ads_anuncios enable row level security;
alter table public.meta_ads_diario   enable row level security;

drop policy if exists meta_ads_anuncios_ler on public.meta_ads_anuncios;
create policy meta_ads_anuncios_ler on public.meta_ads_anuncios
  for select to authenticated using (public.meu_perfil() is not null);
drop policy if exists meta_ads_diario_ler on public.meta_ads_diario;
create policy meta_ads_diario_ler on public.meta_ads_diario
  for select to authenticated using (public.meu_perfil() is not null);

revoke all on public.meta_ads_anuncios, public.meta_ads_diario from anon;
grant select on public.meta_ads_anuncios, public.meta_ads_diario to authenticated;
grant all on public.meta_ads_anuncios, public.meta_ads_diario to service_role;

-- ─────────────────────────────── 3. gravação (n8n) ───────────────────────────────
create or replace function public.meta_ads_gravar(p_insights jsonb, p_anuncios jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ins int := 0;
  v_ads int := 0;
begin
  if jsonb_typeof(coalesce(p_insights, '[]'::jsonb)) <> 'array' or jsonb_typeof(coalesce(p_anuncios, '[]'::jsonb)) <> 'array' then
    raise exception 'p_insights e p_anuncios precisam ser arrays (o "data" da Graph API)' using errcode = '22023';
  end if;

  insert into public.meta_ads_diario as d
    (dia, ad_id, ad_nome, adset_id, adset_nome, campanha_id, campanha_nome,
     gasto, impressoes, alcance, cliques, conversas, acoes, atualizado_em)
  select (r ->> 'date_start')::date, r ->> 'ad_id', r ->> 'ad_name', r ->> 'adset_id', r ->> 'adset_name',
         r ->> 'campaign_id', r ->> 'campaign_name',
         coalesce((r ->> 'spend')::numeric, 0), coalesce((r ->> 'impressions')::int, 0),
         coalesce((r ->> 'reach')::int, 0), coalesce((r ->> 'clicks')::int, 0),
         coalesce((select sum((a ->> 'value')::numeric)::int from jsonb_array_elements(coalesce(r -> 'actions', '[]'::jsonb)) a
                    where a ->> 'action_type' = 'onsite_conversion.messaging_conversation_started_7d'), 0),
         r -> 'actions', now()
    from jsonb_array_elements(coalesce(p_insights, '[]'::jsonb)) r
   where r ->> 'ad_id' is not null and r ->> 'date_start' is not null
  on conflict (dia, ad_id) do update set
    ad_nome = excluded.ad_nome, adset_id = excluded.adset_id, adset_nome = excluded.adset_nome,
    campanha_id = excluded.campanha_id, campanha_nome = excluded.campanha_nome,
    gasto = excluded.gasto, impressoes = excluded.impressoes, alcance = excluded.alcance,
    cliques = excluded.cliques, conversas = excluded.conversas, acoes = excluded.acoes, atualizado_em = now();
  get diagnostics v_ins = row_count;

  insert into public.meta_ads_anuncios as a
    (ad_id, ad_nome, adset_id, adset_nome, campanha_id, campanha_nome, status_efetivo, atualizado_em)
  select r ->> 'id', r ->> 'name', r ->> 'adset_id', r -> 'adset' ->> 'name',
         r ->> 'campaign_id', r -> 'campaign' ->> 'name', r ->> 'effective_status', now()
    from jsonb_array_elements(coalesce(p_anuncios, '[]'::jsonb)) r
   where r ->> 'id' is not null
  on conflict (ad_id) do update set
    ad_nome = excluded.ad_nome, adset_id = excluded.adset_id, adset_nome = excluded.adset_nome,
    campanha_id = excluded.campanha_id, campanha_nome = excluded.campanha_nome,
    status_efetivo = excluded.status_efetivo, atualizado_em = now();
  get diagnostics v_ads = row_count;

  return jsonb_build_object('ok', true, 'insights', v_ins, 'anuncios', v_ads, 'em', now());
end $$;

revoke execute on function public.meta_ads_gravar(jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.meta_ads_gravar(jsonb, jsonb) to service_role;

-- ─────────────────────────────── 4. visão por dia ───────────────────────────────
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
         count(*) filter (where handoff_em is not null)::int                   as qualificadas
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
  'Meta Ads por dia: gasto/conversas da Meta (meta_ads_diario) ao lado das conversas da Mari com origem meta_ads (com CEP, fora da área, qualificadas = handoff) e das vendas meta_ads (biometria aprovada). security_invoker: cada perfil vê o que a RLS das tabelas deixa. 0034.';

grant select on public.v_meta_ads_dia to authenticated;
