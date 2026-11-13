-- NIOGEN | supabase/migrations/0172_dfv_resumos_prontos.sql | 13/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 13/11 ~11h35: "Sim, aliviar" (o banco do plano gratuito trava por falta de memória; ver Diário 13/11 ~11h30).
-- Medido em pg_stat_statements (desde 04/11): v_dfv_resumo leva 5,1 s de média (40 chamadas, até 8 s = limite do usuário logado,
-- 72 MB de arquivo temporário) e v_dfv_bairros 5,9–7,1 s. As duas varriam as 143.824 linhas de nio_hp (62 MB, a maior tabela do
-- banco) a cada abertura do Painel, do Meta Ads e da prévia do DFV em Configurações — para devolver 1 linha e ~200 linhas.
-- A base DFV só muda quando alguém aplica uma importação. Agora o resumo fica pronto em duas tabelas pequenas, refeitas por gatilho
-- quando nio_hp muda (1 vez por comando: o aplicar_dfv faz 1 delete + 1 insert). As views continuam com o mesmo nome, as mesmas
-- colunas e a mesma ordem — as telas não mudam. O importador (aplicar_dfv) não foi tocado (regra 15: peça isolada).
-- Leitura: mesma regra de nio_hp (qualquer usuário com perfil). Escrita: só o gatilho.

-- 1) Tabelas prontas, com os mesmos tipos que as views devolviam.
create table public.dfv_resumo_pronto as
select uf, municipio, max(particao) as particao, count(*)::integer as fachadas, sum(hp_tot)::integer as hp_tot,
       sum(hp_livre)::integer as hp_livre, sum(hc_tot)::integer as hc_tot,
       round(sum(hc_tot)::numeric / nullif(sum(hp_tot), 0)::numeric, 4) as pct_ocupacao,
       count(*) filter (where hp_tot = 1 and hc_tot >= 1)::integer as casas_ocupadas,
       count(*) filter (where tipo_edificacao = 'VERTICAL'::text)::integer as predios,
       count(distinct bairro)::integer as bairros, count(distinct cep)::integer as ceps
  from public.nio_hp group by uf, municipio
with no data;

create table public.dfv_bairros_pronto as
select uf, municipio, bairro, fachadas, hp_tot, hp_livre, pct_livre, hc_tot, hp_emp, pct_aprov_bairro, qt_propostas_bairro,
       aprov_estimada, pct_alto_medio, pct_ab_c, lat_centro, lon_centro, raio_km, score, particao
  from public.v_dfv_bairros
with no data;

alter table public.dfv_resumo_pronto add column parceiro_id text not null default 'dharma', add column refeito_em timestamptz not null default now();
alter table public.dfv_bairros_pronto add column parceiro_id text not null default 'dharma', add column refeito_em timestamptz not null default now();
create index dfv_resumo_pronto_local_idx on public.dfv_resumo_pronto (uf, municipio);
create index dfv_bairros_pronto_local_idx on public.dfv_bairros_pronto (uf, municipio);

alter table public.dfv_resumo_pronto enable row level security;
alter table public.dfv_bairros_pronto enable row level security;
create policy dfv_resumo_pronto_ler on public.dfv_resumo_pronto for select to authenticated using ((select public.meu_perfil()) is not null);
create policy dfv_bairros_pronto_ler on public.dfv_bairros_pronto for select to authenticated using ((select public.meu_perfil()) is not null);
revoke all on public.dfv_resumo_pronto, public.dfv_bairros_pronto from public, anon, authenticated;
grant select on public.dfv_resumo_pronto, public.dfv_bairros_pronto to authenticated, service_role;

-- 2) Quem refaz: a conta que as views faziam, agora uma vez por mudança da base.
create or replace function public.dfv_resumos_refazer() returns void
 language plpgsql security definer set search_path to 'public' as $function$
begin
  delete from public.dfv_resumo_pronto where true;
  insert into public.dfv_resumo_pronto (uf, municipio, particao, fachadas, hp_tot, hp_livre, hc_tot, pct_ocupacao, casas_ocupadas, predios, bairros, ceps)
  select uf, municipio, max(particao), count(*)::integer, sum(hp_tot)::integer, sum(hp_livre)::integer, sum(hc_tot)::integer,
         round(sum(hc_tot)::numeric / nullif(sum(hp_tot), 0)::numeric, 4),
         count(*) filter (where hp_tot = 1 and hc_tot >= 1)::integer,
         count(*) filter (where tipo_edificacao = 'VERTICAL'::text)::integer,
         count(distinct bairro)::integer, count(distinct cep)::integer
    from public.nio_hp group by uf, municipio;

  delete from public.dfv_bairros_pronto where true;
  insert into public.dfv_bairros_pronto (uf, municipio, bairro, fachadas, hp_tot, hp_livre, pct_livre, hc_tot, hp_emp, pct_aprov_bairro,
         qt_propostas_bairro, aprov_estimada, pct_alto_medio, pct_ab_c, lat_centro, lon_centro, raio_km, score, particao)
  with b as (
    select h.uf, h.municipio, h.bairro, count(*)::integer as fachadas, sum(h.hp_tot)::integer as hp_tot, sum(h.hp_livre)::integer as hp_livre,
           sum(h.hc_tot)::integer as hc_tot, sum(h.hp_emp)::integer as hp_emp, max(h.pct_aprov_bairro) as pct_aprov_bairro,
           max(h.qt_propostas_bairro) as qt_propostas_bairro,
           avg(case when h.classificacao = any (array['ALTO'::text, 'MEDIO'::text]) then 1.0 else 0::numeric end) as pct_alto_medio,
           avg(case when h.classe_social = any (array['A/B'::text, 'C'::text]) then 1.0 else 0::numeric end) as pct_ab_c,
           avg(h.lat) as lat_centro, avg(h.lon) as lon_centro,
           sqrt(coalesce(var_pop(h.lat * 111.32::double precision), 0::double precision)
                + coalesce(var_pop(h.lon * 111.32::double precision * cos(radians(h.lat))), 0::double precision)) as dispersao_km,
           max(h.particao) as particao
      from public.nio_hp h group by h.uf, h.municipio, h.bairro),
  m as (
    select b_1.uf, b_1.municipio,
           percentile_cont(0.5::double precision) within group (order by (b_1.pct_aprov_bairro::double precision)) as mediana
      from b b_1 where b_1.pct_aprov_bairro is not null group by b_1.uf, b_1.municipio)
  select b.uf, b.municipio, b.bairro, b.fachadas, b.hp_tot, b.hp_livre,
         round(b.hp_livre::numeric / nullif(b.hp_tot, 0)::numeric, 4), b.hc_tot, b.hp_emp, b.pct_aprov_bairro, b.qt_propostas_bairro,
         b.pct_aprov_bairro is null, round(b.pct_alto_medio, 4), round(b.pct_ab_c, 4),
         round(b.lat_centro::numeric, 6), round(b.lon_centro::numeric, 6), round((1.5::double precision * b.dispersao_km)::numeric, 1),
         round(b.hp_livre::numeric * coalesce(b.pct_aprov_bairro, m.mediana::numeric, 0.5) * (0.5 + 0.5 * b.pct_alto_medio), 0),
         b.particao
    from b left join m on m.uf = b.uf and m.municipio = b.municipio;
end $function$;
revoke all on function public.dfv_resumos_refazer() from public, anon, authenticated;
grant execute on function public.dfv_resumos_refazer() to service_role;

create or replace function public.dfv_resumos_gatilho() returns trigger
 language plpgsql security definer set search_path to 'public' as $function$
begin
  perform public.dfv_resumos_refazer();
  return null;
end $function$;
revoke all on function public.dfv_resumos_gatilho() from public, anon, authenticated;

create trigger nio_hp_refaz_resumos after insert or update or delete or truncate on public.nio_hp
  for each statement execute function public.dfv_resumos_gatilho();

-- 3) Primeira carga, antes de trocar as views.
select public.dfv_resumos_refazer();

-- 4) As views passam a ler o que está pronto: mesmo nome, mesmas colunas, mesma ordem.
create or replace view public.v_dfv_resumo with (security_invoker = true) as
select r.uf, r.municipio, r.particao, r.fachadas, r.hp_tot, r.hp_livre, r.hc_tot, r.pct_ocupacao, r.casas_ocupadas, r.predios, r.bairros, r.ceps,
       (select i.aplicado_em from public.importacoes i where i.tipo = 'dfv_hp'::text and i.aplicado_em is not null
         order by i.aplicado_em desc limit 1) as aplicado_em
  from public.dfv_resumo_pronto r;

create or replace view public.v_dfv_bairros with (security_invoker = true) as
select b.uf, b.municipio, b.bairro, b.fachadas, b.hp_tot, b.hp_livre, b.pct_livre, b.hc_tot, b.hp_emp, b.pct_aprov_bairro, b.qt_propostas_bairro,
       b.aprov_estimada, b.pct_alto_medio, b.pct_ab_c, b.lat_centro, b.lon_centro, b.raio_km, b.score, b.particao
  from public.dfv_bairros_pronto b
 order by b.score desc nulls last, b.hp_livre desc;
