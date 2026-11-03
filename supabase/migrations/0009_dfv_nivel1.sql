-- NIOGEN | supabase/migrations/0009_dfv_nivel1.sql | 03/11/2026
-- DFV Nio (Direcionador da Força de Vendas, Power BI público, Sudeste) — nível 1: uma pessoa consulta a viabilidade
-- do endereço antes da visita de biometria e o resultado fica na venda (docs/DFV_NIO_integracao_031126_1920.md).
-- O APP NiO PAP continua sendo a palavra final; o DFV evita visita perdida e venda indevida.
-- Trava: entrar em 1–5 (vindo de 0, de saída ou já inserida vendida) exige DFV viável consultado há menos de 7 dias,
-- salvo dispensa de admin com motivo. Toda gravação de dfv_* vira evento.
-- O link do painel NÃO está aqui (repo público; ele tem o formato view?r=…): a linha dfv_sudeste de config_links nasce
-- com url null e é preenchida fora do repo (decisão do Ricardo, 03/11). Senhas nunca entram no banco.
--
-- Passo 0 (banco real em 03/11): vendas sem colunas dfv_*, nenhuma tabela config_links, 0 vendas, migrations 0001–0008.

-- ============================================================================
-- vendas: resultado da consulta
-- ============================================================================

alter table public.vendas
  add column if not exists dfv_viabilidade     text not null default 'nao_consultado'
    check (dfv_viabilidade in ('nao_consultado', 'viavel', 'viavel_predio', 'sem_viabilidade', 'nao_encontrado')),
  add column if not exists dfv_consultado_em   timestamptz,
  add column if not exists dfv_consultado_por  uuid references public.usuarios (id),
  add column if not exists dfv_faixa_credito   text check (dfv_faixa_credito in ('<50', '50-70', '>70', 'nao_informado')),
  add column if not exists dfv_classificacao   text check (dfv_classificacao in ('ALTO', 'MEDIO', 'BAIXO')),
  add column if not exists dfv_hp_livre        int,
  add column if not exists dfv_hcs             int,
  add column if not exists dfv_dispensado      boolean not null default false,
  add column if not exists dfv_dispensa_motivo text;

comment on column public.vendas.dfv_viabilidade is
  'Resultado da consulta manual no DFV Nio (página 3). Viável ou viável (prédio) + consulta < 7 dias libera 0 → 1. Palavra final: APP NiO PAP.';

-- ============================================================================
-- Carimbo da consulta (roda antes de vendas_antes_status: BEFORE em ordem alfabética)
-- ============================================================================

create or replace function public.vendas_antes_dfv()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  mudou boolean;
begin
  if tg_op = 'INSERT' then
    mudou := new.dfv_viabilidade <> 'nao_consultado';
  else
    mudou := new.dfv_viabilidade is distinct from old.dfv_viabilidade
          or new.dfv_faixa_credito is distinct from old.dfv_faixa_credito
          or new.dfv_classificacao is distinct from old.dfv_classificacao
          or new.dfv_hp_livre is distinct from old.dfv_hp_livre
          or new.dfv_hcs is distinct from old.dfv_hcs;
  end if;

  -- Nova leitura do DFV: carimba quando e quem (se o front não mandou a data, é agora; nunca no futuro).
  if mudou then
    if tg_op = 'INSERT' or new.dfv_consultado_em is not distinct from old.dfv_consultado_em then
      new.dfv_consultado_em := now();
    end if;
    new.dfv_consultado_em := least(coalesce(new.dfv_consultado_em, now()), now());
    new.dfv_consultado_por := coalesce(auth.uid(), new.dfv_consultado_por);
  end if;
  if new.dfv_viabilidade = 'nao_consultado' then
    new.dfv_consultado_em := null;
    new.dfv_consultado_por := null;
  end if;

  -- Dispensa: só admin, sempre com motivo.
  if new.dfv_dispensado and (tg_op = 'INSERT' or not old.dfv_dispensado) then
    if coalesce(public.meu_perfil(), '') <> 'admin' then
      raise exception 'Só admin dispensa a consulta do DFV.' using errcode = '42501';
    end if;
    if coalesce(btrim(new.dfv_dispensa_motivo), '') = '' then
      raise exception 'Dispensa do DFV exige motivo.' using errcode = 'P0001';
    end if;
  end if;
  if not new.dfv_dispensado then
    new.dfv_dispensa_motivo := null;
  end if;
  return new;
end;
$$;

drop trigger if exists vendas_antes_dfv on public.vendas;
create trigger vendas_antes_dfv
  before insert or update on public.vendas
  for each row execute function public.vendas_antes_dfv();

-- ============================================================================
-- Trava 0 → 1 (mesmo trigger que exige pedido e biometria)
-- ============================================================================

create or replace function public.vendas_antes_status()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  mudou   boolean := tg_op = 'INSERT' or new.status is distinct from old.status;
  vendida boolean := new.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme');
begin
  if not mudou then
    return new;
  end if;

  -- Sem pedido do APP NiO PAP e biometria aprovada não existe venda (Anexo II).
  if vendida
     and (coalesce(btrim(new.nio_pedido), '') = '' or new.biometria_status is distinct from 'aprovada') then
    raise exception 'Venda bloqueada: para passar de Qualificado é obrigatório o nº do pedido do APP NiO PAP e a biometria aprovada.'
      using errcode = 'P0001';
  end if;

  -- DFV: só na entrada em 1–5 (de Qualificado, de Saída ou já inserida vendida). O OSAB levando 2 → 3 → 4 não passa aqui.
  if vendida and (tg_op = 'INSERT' or old.status in ('0_qualificado', 'saida'))
     and not new.dfv_dispensado
     and not (new.dfv_viabilidade in ('viavel', 'viavel_predio') and new.dfv_consultado_em >= now() - interval '7 days') then
    raise exception 'Consulte o DFV (viabilidade) antes de registrar a venda — resultado deve ser viável e ter menos de 7 dias.'
      using errcode = 'P0001';
  end if;

  if new.status = 'saida' and coalesce(btrim(new.motivo_saida), '') = '' then
    raise exception 'Saída exige motivo.' using errcode = 'P0001';
  end if;

  if new.status = '1_vendido' then
    new.vendido_em := coalesce(new.vendido_em, now());
  elsif new.status = '2_aguardando_instalacao' then
    new.vendido_em := coalesce(new.vendido_em, now());
    new.agendamento_registrado_em := now();
  elsif new.status = '3_instalado' then
    new.instalado_em := coalesce(new.instalado_em, now());
  elsif new.status = '4_ativo_provisorio' then
    new.ativado_em := coalesce(new.ativado_em, now());
  end if;

  return new;
end;
$$;

-- ============================================================================
-- Evento de toda gravação do DFV
-- ============================================================================

create or replace function public.vendas_registra_dfv()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.dfv_viabilidade <> 'nao_consultado' then
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (new.id, 'dfv_consulta', jsonb_strip_nulls(jsonb_build_object(
        'viabilidade', new.dfv_viabilidade, 'consultado_em', new.dfv_consultado_em, 'faixa_credito', new.dfv_faixa_credito,
        'classificacao', new.dfv_classificacao, 'hp_livre', new.dfv_hp_livre, 'hcs', new.dfv_hcs)), auth.uid());
    end if;
  elsif row(new.dfv_viabilidade, new.dfv_consultado_em, new.dfv_faixa_credito, new.dfv_classificacao, new.dfv_hp_livre, new.dfv_hcs)
        is distinct from row(old.dfv_viabilidade, old.dfv_consultado_em, old.dfv_faixa_credito, old.dfv_classificacao, old.dfv_hp_livre, old.dfv_hcs) then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (new.id, 'dfv_consulta', jsonb_strip_nulls(jsonb_build_object(
      'viabilidade', new.dfv_viabilidade, 'de', old.dfv_viabilidade, 'consultado_em', new.dfv_consultado_em,
      'faixa_credito', new.dfv_faixa_credito, 'classificacao', new.dfv_classificacao, 'hp_livre', new.dfv_hp_livre, 'hcs', new.dfv_hcs)), auth.uid());
  end if;

  if new.dfv_dispensado and (tg_op = 'INSERT' or not old.dfv_dispensado) then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (new.id, 'dfv_dispensa', jsonb_build_object('motivo', new.dfv_dispensa_motivo), auth.uid());
  end if;
  return null;
end;
$$;

drop trigger if exists vendas_registra_dfv on public.vendas;
create trigger vendas_registra_dfv
  after insert or update of dfv_viabilidade, dfv_consultado_em, dfv_faixa_credito, dfv_classificacao, dfv_hp_livre, dfv_hcs, dfv_dispensado
  on public.vendas
  for each row execute function public.vendas_registra_dfv();

revoke execute on function public.vendas_antes_dfv()    from public, anon, authenticated;
revoke execute on function public.vendas_antes_status() from public, anon, authenticated;
revoke execute on function public.vendas_registra_dfv() from public, anon, authenticated;

-- ============================================================================
-- Links de ferramentas da Nio (o URL do DFV entra fora do repo)
-- ============================================================================

create table if not exists public.config_links (
  chave         text primary key,
  nome          text not null,
  url           text,
  observacao    text,
  atualizado_em timestamptz not null default now()
);

alter table public.config_links enable row level security;
drop policy if exists config_links_ler on public.config_links;
create policy config_links_ler on public.config_links
  for select to authenticated using (public.meu_perfil() is not null);
drop policy if exists config_links_admin on public.config_links;
create policy config_links_admin on public.config_links
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');
revoke all on public.config_links from anon;

insert into public.config_links (chave, nome, url, observacao) values
  ('dfv_sudeste', 'DFV Nio · Sudeste (MG, ES, RJ)', null,
   'Power BI público da Nio. Usuário PARCEIRO + 2 senhas (com o Ricardo / gerenciador de senhas). URL gravado fora do repo — ver INFRA.md › DFV Nio.')
on conflict (chave) do nothing;

-- ============================================================================
-- Views recriadas (v.* passa a trazer dfv_*) + v_placar_dfv
-- ============================================================================

drop view if exists public.v_placar_dfv;
drop view if exists public.v_painel_hoje;
drop view if exists public.v_painel_mes;
drop view if exists public.v_alertas_contrato;
drop view if exists public.v_instalacoes;
drop view if exists public.v_funil;

create view public.v_funil
with (security_invoker = true) as
select
  v.*,
  p.nome          as plano_nome,
  p.familia       as plano_familia,
  p.velocidade    as plano_velocidade,
  p.preco         as plano_preco,
  p.codigo        as plano_codigo,
  p.portfolio     as plano_portfolio,
  p.variante      as plano_variante,
  p.cluster       as plano_cluster,
  p.preco_cartao  as plano_preco_cartao,
  p.taxa_a_vista  as plano_taxa_a_vista,
  p.isencao_meses as plano_isencao_meses,
  u.nome          as vendedor_nome,
  case
    when v.status = '1_vendido' and v.agendamento_registrado_em is null and v.vendido_em is not null
      then round((extract(epoch from now() - v.vendido_em) / 3600)::numeric, 2)
  end as horas_sem_agendamento,
  case
    when v.status = '0_qualificado' and v.biometria_status is distinct from 'aprovada'
      then round((extract(epoch from now() - v.criado_em) / 86400)::numeric, 2)
  end as dias_esperando_biometria,
  (v.instalado_em + interval '15 days')  as docs_prazo_em,
  (v.instalado_em + interval '180 days') as firme_em,
  -- DFV: consulta viável e com menos de 7 dias (a mesma regra da trava em vendas_antes_status)
  (v.dfv_viabilidade in ('viavel', 'viavel_predio') and v.dfv_consultado_em >= now() - interval '7 days') as dfv_ok,
  case when v.dfv_consultado_em is not null then floor(extract(epoch from now() - v.dfv_consultado_em) / 86400)::int end as dfv_dias
from public.vendas v
left join public.config_planos p on p.id = v.plano_id
left join public.usuarios u on u.id = v.vendedor_id;

create view public.v_instalacoes
with (security_invoker = true) as
with base as (
  select
    f.*,
    (now() at time zone 'America/Sao_Paulo')::date                          as hoje_sp,
    (f.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date     as agendada_dia_sp
  from public.v_funil f
  where f.status in ('1_vendido', '2_aguardando_instalacao')
     or (f.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') and f.instalado_em >= now() - interval '7 days')
)
select
  b.*,
  case
    when b.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') then 'concluida'
    when b.nio_pendencia_cod is not null or b.nio_pendencia_desc is not null  then 'pendencia'
    when b.status = '1_vendido' or b.instalacao_agendada_para is null         then 'agendar'
    when b.agendada_dia_sp < b.hoje_sp                                        then 'pendencia'   -- data passou sem instalar
    when b.agendada_dia_sp = b.hoje_sp                                        then 'hoje'
    when b.agendada_dia_sp = b.hoje_sp + 1                                    then 'amanha'
    else 'semana'
  end as coluna
from base b;

create view public.v_alertas_contrato
with (security_invoker = true) as
select f.id as venda_id, f.cliente_nome, 'venda_invalida'::text as tipo, 'bad'::text as nivel,
       'Nio marcou venda inválida' || coalesce(' · ' || f.nio_pendencia_desc, '') as texto,
       'venda.html?id=' || f.id as link, f.nio_osab_em as desde, null::numeric as horas
from public.v_funil f
where f.nio_venda_valida is false and f.status <> '5_comissao_firme'
union all
select f.id, f.cliente_nome, 'risco_contrato', 'bad',
       'Risco de multa/estorno · ' || coalesce(f.nio_pendencia_desc, f.motivo_saida),
       'venda.html?id=' || f.id, f.nio_osab_em, null
from public.v_funil f
where f.nio_venda_valida is not false
  and public.osab_risco(null, f.nio_pendencia_desc, f.motivo_saida)
union all
select f.id, f.cliente_nome, 'sem_agendamento', 'bad',
       'vendida há ' || floor(f.horas_sem_agendamento)::int || 'h'
         || lpad((round((f.horas_sem_agendamento - floor(f.horas_sem_agendamento)) * 60))::int::text, 2, '0') || ' sem agendamento',
       'instalacoes.html', f.vendido_em, f.horas_sem_agendamento
from public.v_funil f
where f.horas_sem_agendamento > 4
union all
select f.id, f.cliente_nome, 'docs', case when f.docs_prazo_em < now() then 'bad' else 'warn' end,
       case when f.docs_prazo_em < now() then 'documentos à Nio atrasados desde ' else 'documentos à Nio até ' end
         || to_char(f.docs_prazo_em at time zone 'America/Sao_Paulo', 'DD/MM'),
       'venda.html?id=' || f.id, f.instalado_em, null
from public.v_funil f
where f.docs_entregues_em is null and f.docs_prazo_em is not null
  and f.docs_prazo_em <= now() + interval '3 days'
  and f.status in ('3_instalado', '4_ativo_provisorio')
union all
select f.id, f.cliente_nome, 'dfv_nao_consultado', 'warn',
       'DFV não consultado · ' || case when f.biometria_status = 'agendada' then 'biometria marcada' else 'visita marcada' end,
       'venda.html?id=' || f.id, coalesce(f.biometria_em, f.instalacao_agendada_para, f.criado_em), null
from public.v_funil f
where f.status = '0_qualificado' and f.dfv_viabilidade = 'nao_consultado' and not f.dfv_dispensado
  and (f.biometria_status = 'agendada' or f.biometria_em is not null or f.instalacao_agendada_para is not null)
union all
select f.id, f.cliente_nome, 'dfv_sem_cobertura', 'bad',
       'DFV: ' || case when f.dfv_viabilidade = 'sem_viabilidade' then 'endereço sem viabilidade' else 'endereço não encontrado' end || ' · não vender',
       'venda.html?id=' || f.id, f.dfv_consultado_em, null
from public.v_funil f
where f.dfv_viabilidade in ('sem_viabilidade', 'nao_encontrado') and f.status <> 'saida';

create view public.v_painel_mes
with (security_invoker = true) as
with base as (
  select
    f.*,
    date_trunc('month', f.vendido_em at time zone 'America/Sao_Paulo')::date as mes_venda,
    (f.vendido_em at time zone 'America/Sao_Paulo')::date                    as dia_venda,
    date_trunc('month', f.instalado_em at time zone 'America/Sao_Paulo')::date as mes_inst,
    (f.instalado_em at time zone 'America/Sao_Paulo')::date                  as dia_inst,
    f.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')    as instalada,
    public.osab_risco(f.nio_venda_valida, f.nio_pendencia_desc, f.motivo_saida) as em_risco
  from public.v_funil f
),
vend as (
  select * from base
  where vendido_em is not null
    and status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme')
    and nio_venda_valida is not false
),
saidas as (
  select e.venda_id, date_trunc('month', e.criado_em at time zone 'America/Sao_Paulo')::date as mes
  from public.eventos_venda e
  where (e.tipo = 'status' and e.detalhe ->> 'para' = 'saida')
     or (e.tipo = 'criada' and e.detalhe ->> 'status' = 'saida')
),
meses as (
  select mes_venda as mes from vend
  union
  select mes from public.config_metas
)
select
  m.mes,
  cm.meta_vendas,
  (select count(*) from vend where mes_venda = m.mes)::int                         as vendidas,
  (select count(*) from vend where mes_venda = m.mes and instalada)::int           as instaladas,
  (select count(*) from vend where mes_venda = m.mes and not instalada)::int       as aguardando,
  (select count(*) from base
    where status in ('4_ativo_provisorio', '5_comissao_firme')
      and coalesce(ativado_em, instalado_em) < ((m.mes + interval '1 month')::timestamp at time zone 'America/Sao_Paulo'))::int as ativas_carteira,
  (select count(distinct s.venda_id) from saidas s where s.mes = m.mes)::int       as saidas,
  (select b.motivo_saida from saidas s join base b on b.id = s.venda_id
    where s.mes = m.mes and b.motivo_saida is not null
    group by b.motivo_saida order by count(*) desc, b.motivo_saida limit 1)        as saidas_motivo_top,
  (select coalesce(sum(comissao_prevista), 0) from vend where mes_venda = m.mes)    as comissao_prevista,
  (select coalesce(sum(comissao_prevista), 0) from vend where mes_venda = m.mes and instalada) as comissao_instalada,
  (select coalesce(sum(comissao_prevista), 0) from base where mes_venda = m.mes and em_risco and status <> 'saida') as comissao_em_risco,
  (select coalesce(sum(comissao_nominal), 0) from vend where mes_venda = m.mes)         as comissao_nominal,
  (select coalesce(sum(comissao_adicionais), 0) from vend where mes_venda = m.mes)      as comissao_adicionais,
  (select coalesce(sum(bonus_transicao_previsto), 0) from vend where mes_venda = m.mes) as bonus_transicao,
  (select coalesce(sum(bonus_nmei_previsto), 0) from vend where mes_venda = m.mes)      as bonus_nmei,
  (select coalesce(sum(bonus_m10_potencial), 0) from vend where mes_venda = m.mes)      as bonus_m10_potencial,
  (select coalesce(jsonb_object_agg(origem, n), '{}'::jsonb)
     from (select origem, count(*) n from vend where mes_venda = m.mes group by origem) x)   as por_origem,
  (select coalesce(jsonb_object_agg(coalesce(cidade, '—'), n), '{}'::jsonb)
     from (select cidade, count(*) n from vend where mes_venda = m.mes group by cidade) x)   as por_cidade,
  (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'vendidas', n, 'instaladas', i) order by n desc, nome), '[]'::jsonb)
     from (select coalesce(vendedor_nome, '—') nome, count(*) n, count(*) filter (where instalada) i
           from vend where mes_venda = m.mes group by 1) x)                                  as por_vendedor,
  (select coalesce(jsonb_object_agg(coalesce(plano_nome, '—'), n), '{}'::jsonb)
     from (select plano_nome, count(*) n from vend where mes_venda = m.mes group by plano_nome) x) as por_plano,
  (select coalesce(jsonb_object_agg(coalesce(forma_pagamento, '—'), n), '{}'::jsonb)
     from (select forma_pagamento, count(*) n from vend where mes_venda = m.mes group by forma_pagamento) x) as por_forma,
  (select coalesce(jsonb_object_agg(dia_venda::text, n), '{}'::jsonb)
     from (select dia_venda, count(*) n from vend where mes_venda = m.mes group by dia_venda) x) as por_dia_vendas,
  (select coalesce(jsonb_object_agg(dia_inst::text, n), '{}'::jsonb)
     from (select dia_inst, count(*) n from base where mes_inst = m.mes and instalada group by dia_inst) x) as por_dia_instaladas
from meses m
left join public.config_metas cm on cm.mes = m.mes;

create view public.v_painel_hoje
with (security_invoker = true) as
with f as (
  select v.*, (now() at time zone 'America/Sao_Paulo')::date as hoje
  from public.v_funil v
)
select
  max(hoje) as hoje,
  count(*) filter (where (vendido_em at time zone 'America/Sao_Paulo')::date = hoje
                     and status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme')
                     and nio_venda_valida is not false)::int                                                      as vendas_hoje,
  count(*) filter (where (instalado_em at time zone 'America/Sao_Paulo')::date = hoje)::int                       as instaladas_hoje,
  count(*) filter (where (biometria_em at time zone 'America/Sao_Paulo')::date = hoje
                     and biometria_status in ('agendada', 'aprovada'))::int                                       as biometrias_hoje,
  count(*) filter (where status = '0_qualificado')::int                                                           as qualificados,
  count(*) filter (where status = '0_qualificado' and biometria_status is distinct from 'aprovada')::int         as esperando_biometria,
  count(*) filter (where horas_sem_agendamento > 4)::int                                                          as sem_agendamento_4h,
  count(*) filter (where (instalacao_agendada_para at time zone 'America/Sao_Paulo')::date = hoje
                     and instalado_em is null and status in ('1_vendido', '2_aguardando_instalacao'))::int        as instalacoes_agendadas_hoje,
  count(*) filter (where status in ('1_vendido', '2_aguardando_instalacao')
                     and (nio_pendencia_cod is not null or nio_pendencia_desc is not null))::int                  as pendencias_osab,
  mode() within group (order by nio_pendencia_desc) filter (where status in ('1_vendido', '2_aguardando_instalacao')
                     and nio_pendencia_desc is not null)                                                          as pendencia_top
from f;

-- Placar do DFV: qualificadas que entraram no mês, quantas tiveram o DFV consultado e quantas deram viável.
create view public.v_placar_dfv
with (security_invoker = true) as
select
  date_trunc('month', v.criado_em at time zone 'America/Sao_Paulo')::date                         as mes,
  count(*)::int                                                                                   as qualificadas,
  count(*) filter (where v.dfv_viabilidade <> 'nao_consultado')::int                              as dfv_consultadas,
  count(*) filter (where v.dfv_viabilidade in ('viavel', 'viavel_predio'))::int                   as dfv_viaveis,
  count(*) filter (where v.dfv_viabilidade in ('sem_viabilidade', 'nao_encontrado'))::int         as dfv_sem_cobertura,
  count(*) filter (where v.dfv_dispensado)::int                                                   as dfv_dispensadas,
  round(100.0 * count(*) filter (where v.dfv_viabilidade in ('viavel', 'viavel_predio'))
        / nullif(count(*) filter (where v.dfv_viabilidade <> 'nao_consultado'), 0), 1)            as pct_viavel_consultadas,
  round(100.0 * count(*) filter (where v.dfv_viabilidade in ('viavel', 'viavel_predio')) / nullif(count(*), 0), 1) as pct_viavel_qualificadas
from public.vendas v
group by 1;

grant select on public.v_funil, public.v_instalacoes, public.v_alertas_contrato, public.v_painel_mes, public.v_painel_hoje, public.v_placar_dfv to authenticated;
revoke all on public.v_funil, public.v_instalacoes, public.v_alertas_contrato, public.v_painel_mes, public.v_painel_hoje, public.v_placar_dfv from anon;
