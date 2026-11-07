-- NIOGEN | supabase/migrations/0054_meta_ads_posicionamento.sql | 07/11/2026 — Claude Code (pedido do Ricardo, "Pode")
-- Por quê: em 06–07/11 o Status do WhatsApp levou 47 % da verba da campanha 1 (R$ 41,76 de R$ 89,21) com 0 conversas,
-- e nada no NIOGEN via isso — meta_ads_diario (0034) só guarda anúncio × dia, sem posicionamento. Esta migration dá ao
-- futuro agente de Meta Ads (docs/META_ADS_campanha1_JF_051126_2230.md §7) o corte que faltou:
--   1. meta_ads_posicionamento_diario — conjunto × posicionamento × dia (insights level=adset,
--      breakdowns=publisher_platform,platform_position). Gravado só pelo n8n (meta_ads_coleta).
--   2. config_meta_ads_regras — limites das regras do agente (regra 15: nada fixo no código). Valores iniciais = os do doc.
--   3. meta_ads_gravar_posicionamentos(p_insights) — upsert idempotente, só service role.
--   4. v_meta_ads_posicionamento_7d — últimos 7 dias por campanha × posicionamento: fatia do gasto, CTR, custo por
--      conversa e `alerta` quando um posicionamento come verba sem conversa (a regra que teria pego o Status do WhatsApp).
-- Só leitura para o front. Nada aqui pausa, ativa, edita ou muda verba: o agente PROPÕE, o Ricardo aprova.
-- parceiro_id (regra 15 do CLAUDE.md): o agente PAP dono da operação, hoje só 'dharma'. Não confundir com
-- public.parceiros (Programa Parceiro PAP, 0035).

-- ─────────────────────────────── 1. conjunto × posicionamento × dia ───────────────────────────────
create table if not exists public.meta_ads_posicionamento_diario (
  parceiro_id       text not null default 'dharma',
  dia               date not null,
  adset_id          text not null,
  adset_nome        text,
  campanha_id       text,
  campanha_nome     text,
  plataforma        text not null,            -- publisher_platform: facebook, instagram, whatsapp, audience_network, messenger
  posicao           text not null,            -- platform_position: feed, instagram_stories, status, an_classic…
  gasto             numeric(12, 2) not null default 0,
  impressoes        int not null default 0,
  cliques           int not null default 0,
  cliques_link      int not null default 0,   -- inline_link_clicks
  conversas         int not null default 0,   -- onsite_conversion.messaging_conversation_started_7d
  acoes             jsonb,
  atualizado_em     timestamptz not null default now(),
  primary key (dia, adset_id, plataforma, posicao)
);
create index if not exists meta_ads_posic_campanha_idx on public.meta_ads_posicionamento_diario (campanha_id, dia);

comment on table public.meta_ads_posicionamento_diario is
  'Insights da Meta por conjunto × posicionamento × dia (fuso da conta). Gravado só pelo n8n (meta_ads_coleta) via meta_ads_gravar_posicionamentos. 0054.';

alter table public.meta_ads_posicionamento_diario enable row level security;
drop policy if exists meta_ads_posic_ler on public.meta_ads_posicionamento_diario;
create policy meta_ads_posic_ler on public.meta_ads_posicionamento_diario
  for select to authenticated using (public.meu_perfil() is not null);
revoke all on public.meta_ads_posicionamento_diario from anon;
grant select on public.meta_ads_posicionamento_diario to authenticated;
grant all on public.meta_ads_posicionamento_diario to service_role;

-- ─────────────────────────────── 2. limites das regras do agente ───────────────────────────────
create table if not exists public.config_meta_ads_regras (
  parceiro_id   text not null default 'dharma',
  chave         text not null,
  valor         numeric not null,
  descricao     text not null,
  atualizado_em timestamptz not null default now(),
  primary key (parceiro_id, chave)
);
comment on table public.config_meta_ads_regras is
  'Limites das regras do agente de Meta Ads (propostas ao Ricardo, nunca ação automática). Editável sem deploy. 0054.';

insert into public.config_meta_ads_regras (chave, valor, descricao) values
  ('posic_gasto_min',     30,   'Posicionamento só entra no alerta depois de gastar ao menos isto (R$) na janela de 7 dias'),
  ('posic_fatia_min',     0.30, 'Fatia mínima do gasto da campanha (0–1) para o posicionamento sem conversa virar alerta'),
  ('anuncio_gasto_pausa', 60,   'Anúncio com este gasto (R$) e 0 CEP válido → propor pausar (regra de bolso do doc §6)'),
  ('conjunto_custo_venda_max', 150, 'Conjunto com custo por venda acima disto (R$) depois de 3 vendas → propor rever')
on conflict (parceiro_id, chave) do nothing;

alter table public.config_meta_ads_regras enable row level security;
drop policy if exists config_meta_ads_regras_ler on public.config_meta_ads_regras;
create policy config_meta_ads_regras_ler on public.config_meta_ads_regras
  for select to authenticated using (public.meu_perfil() is not null);
revoke all on public.config_meta_ads_regras from anon;
grant select on public.config_meta_ads_regras to authenticated;
grant all on public.config_meta_ads_regras to service_role;

-- ─────────────────────────────── 3. gravação (n8n) ───────────────────────────────
create or replace function public.meta_ads_gravar_posicionamentos(p_insights jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_n int := 0;
begin
  if jsonb_typeof(coalesce(p_insights, '[]'::jsonb)) <> 'array' then
    raise exception 'p_insights precisa ser array (o "data" da Graph API)' using errcode = '22023';
  end if;

  insert into public.meta_ads_posicionamento_diario as d
    (dia, adset_id, adset_nome, campanha_id, campanha_nome, plataforma, posicao,
     gasto, impressoes, cliques, cliques_link, conversas, acoes, atualizado_em)
  select (r ->> 'date_start')::date, r ->> 'adset_id', r ->> 'adset_name', r ->> 'campaign_id', r ->> 'campaign_name',
         r ->> 'publisher_platform', r ->> 'platform_position',
         coalesce((r ->> 'spend')::numeric, 0), coalesce((r ->> 'impressions')::int, 0),
         coalesce((r ->> 'clicks')::int, 0), coalesce((r ->> 'inline_link_clicks')::int, 0),
         coalesce((select sum((a ->> 'value')::numeric)::int from jsonb_array_elements(coalesce(r -> 'actions', '[]'::jsonb)) a
                    where a ->> 'action_type' = 'onsite_conversion.messaging_conversation_started_7d'), 0),
         r -> 'actions', now()
    from jsonb_array_elements(coalesce(p_insights, '[]'::jsonb)) r
   where r ->> 'adset_id' is not null and r ->> 'date_start' is not null
     and r ->> 'publisher_platform' is not null and r ->> 'platform_position' is not null
  on conflict (dia, adset_id, plataforma, posicao) do update set
    adset_nome = excluded.adset_nome, campanha_id = excluded.campanha_id, campanha_nome = excluded.campanha_nome,
    gasto = excluded.gasto, impressoes = excluded.impressoes, cliques = excluded.cliques,
    cliques_link = excluded.cliques_link, conversas = excluded.conversas, acoes = excluded.acoes, atualizado_em = now();
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'posicionamentos', v_n, 'em', now());
end $$;

revoke execute on function public.meta_ads_gravar_posicionamentos(jsonb) from public, anon, authenticated;
grant execute on function public.meta_ads_gravar_posicionamentos(jsonb) to service_role;

-- ─────────────────────────────── 4. últimos 7 dias, com alerta ───────────────────────────────
create or replace view public.v_meta_ads_posicionamento_7d
with (security_invoker = true) as
with
lim as (
  select max(valor) filter (where chave = 'posic_gasto_min') as gasto_min,
         max(valor) filter (where chave = 'posic_fatia_min') as fatia_min
    from public.config_meta_ads_regras where parceiro_id = 'dharma'
),
p as (
  select parceiro_id, campanha_id, max(campanha_nome) as campanha_nome, plataforma, posicao,
         sum(gasto) as gasto, sum(impressoes)::int as impressoes, sum(cliques)::int as cliques,
         sum(cliques_link)::int as cliques_link, sum(conversas)::int as conversas,
         min(dia) as desde, max(dia) as ate, max(atualizado_em) as atualizado_em
    from public.meta_ads_posicionamento_diario
   where dia >= (now() at time zone 'America/Sao_Paulo')::date - 6
   group by parceiro_id, campanha_id, plataforma, posicao
),
t as (select campanha_id, sum(gasto) as gasto_campanha from p group by campanha_id)
select p.parceiro_id, p.campanha_id, p.campanha_nome, p.plataforma, p.posicao,
       p.gasto, p.impressoes, p.cliques, p.cliques_link, p.conversas,
       round(p.gasto / nullif(t.gasto_campanha, 0), 4)                          as fatia_gasto,
       round(100.0 * p.cliques_link / nullif(p.impressoes, 0), 2)               as ctr_link_pct,
       round(p.gasto / nullif(p.conversas, 0), 2)                               as custo_conversa,
       (p.conversas = 0 and p.gasto >= lim.gasto_min
        and p.gasto / nullif(t.gasto_campanha, 0) >= lim.fatia_min)             as alerta,
       p.desde, p.ate, p.atualizado_em
  from p join t using (campanha_id) cross join lim;

comment on view public.v_meta_ads_posicionamento_7d is
  'Meta Ads, últimos 7 dias, por campanha × posicionamento. alerta = 0 conversas, gasto ≥ posic_gasto_min e fatia ≥ posic_fatia_min (config_meta_ads_regras). O agente usa isto para PROPOR excluir o posicionamento. 0054.';

grant select on public.v_meta_ads_posicionamento_7d to authenticated;
