-- NIOGEN | supabase/migrations/0042_parceiro_views.sql | 06/11/2026 — Claude Code (prompt nº 22, etapa 1)
-- Views do Programa Parceiro PAP para o Admin (etapa 2). security_invoker: o RLS de quem consulta vale
-- (admin e backoffice leem; vendedor e anon não veem nada).
-- Não mexe em v_funil/v_instalacoes: as colunas novas de `vendas` entram nelas na etapa 2 (v.* congela na criação).

-- ─────────────────────── v_parceiro_pontos_mes ───────────────────────
-- Uma linha por parceiro × mês com pontos + o mês corrente de todo parceiro não desligado (mesmo com 0).
create or replace view public.v_parceiro_pontos_mes
with (security_invoker = true) as
with mes as (
  select parceiro_id, competencia, sum(pontos) as pontos
    from public.pontos_lancamentos group by parceiro_id, competencia
), base as (
  select parceiro_id, competencia from mes
  union
  select p.id, date_trunc('month', now() at time zone 'America/Sao_Paulo')::date
    from public.parceiros p where p.status <> 'desligado'
), deg as (
  select (e ->> 'pontos')::numeric as pontos, (e ->> 'premio')::numeric as premio
    from public.config_parceiros c, jsonb_array_elements(c.degraus) e
)
select
  b.parceiro_id,
  p.nome  as parceiro_nome,
  p.status as parceiro_status,
  b.competencia,
  coalesce(m.pontos, 0)::numeric(12, 2) as pontos,
  (select max(d.pontos) from deg d where d.pontos <= coalesce(m.pontos, 0)) as degrau_pontos,
  (select d.premio from deg d where d.pontos <= coalesce(m.pontos, 0) order by d.pontos desc limit 1) as degrau_premio,
  (select min(d.pontos) from deg d where d.pontos > coalesce(m.pontos, 0)) as proximo_degrau_pontos,
  (select d.premio from deg d where d.pontos > coalesce(m.pontos, 0) order by d.pontos limit 1) as proximo_degrau_premio,
  (select min(d.pontos) from deg d where d.pontos > coalesce(m.pontos, 0)) - coalesce(m.pontos, 0) as faltam_pontos,
  exists (select 1 from public.parceiro_apuracoes a where a.competencia = b.competencia) as apurado
from base b
join public.parceiros p on p.id = b.parceiro_id
left join mes m on m.parceiro_id = b.parceiro_id and m.competencia = b.competencia;

comment on view public.v_parceiro_pontos_mes is
  'Pontos do mês, degrau atingido (só o maior), próximo degrau e quanto falta — termômetro M1 do plano.';

-- ─────────────────────── v_parceiro_indicadores ───────────────────────
-- Sinais de qualidade por parceiro (decisão de suspender/desligar é do Ricardo).
--  pct_reprovadas  = reprovadas na conferência ÷ enviadas.
--  instaladas      = instalação CONFIRMADA (Concluído + válida), a mesma regra do pagamento.
--  cancel_30d      = instaladas que a Nio mostra cancelada até 30 d depois da ativação (aproximação: usa nio_osab_em,
--                    a última passada do OSAB pela venda — a data exata do cancelamento não é guardada).
--  indevidas       = a Nio marcou a venda como inválida (fg_venda_valida = false).
--  fraude          = conferência reprovada por suspeita_fraude.
--  inadimplentes_1a_fatura = NULL por enquanto: a tabela de faturas (adimplência, rascunho 0022) ainda não foi aplicada.
create or replace view public.v_parceiro_indicadores
with (security_invoker = true) as
select
  p.id as parceiro_id,
  p.nome as parceiro_nome,
  p.status as parceiro_status,
  count(v.id)                                                     as enviadas,
  count(v.id) filter (where v.conferencia_status = 'aprovada')    as aprovadas,
  count(v.id) filter (where v.conferencia_status = 'reprovada')   as reprovadas,
  count(v.id) filter (where v.conferencia_status = 'devolvida')   as devolvidas,
  count(v.id) filter (where v.conferencia_status = 'pendente')    as em_conferencia,
  round(100.0 * count(v.id) filter (where v.conferencia_status = 'reprovada') / nullif(count(v.id), 0), 1) as pct_reprovadas,
  count(v.id) filter (where v.nio_situacao = 'Concluído' and v.nio_venda_valida is true and v.instalado_em is not null) as instaladas,
  count(v.id) filter (where v.instalado_em is not null and public.osab_cancelada(v.nio_situacao)
                        and v.nio_osab_em <= coalesce(v.ativado_em, v.instalado_em) + interval '30 days') as cancel_30d,
  round(100.0 * count(v.id) filter (where v.instalado_em is not null and public.osab_cancelada(v.nio_situacao)
                        and v.nio_osab_em <= coalesce(v.ativado_em, v.instalado_em) + interval '30 days')
        / nullif(count(v.id) filter (where v.nio_situacao = 'Concluído' and v.nio_venda_valida is true and v.instalado_em is not null), 0), 1) as pct_cancel_30d,
  count(v.id) filter (where v.nio_venda_valida is false)          as indevidas,
  count(v.id) filter (where v.conferencia_motivo = 'suspeita_fraude') as fraude,
  null::bigint as inadimplentes_1a_fatura
from public.parceiros p
left join public.vendas v on v.parceiro_id = p.id
group by p.id, p.nome, p.status;

-- ─────────────────────── v_parceiro_a_pagar ───────────────────────
-- O que vence hoje ou está atrasado, com a chave Pix e se o titular foi conferido (sem isso não dá para marcar pago).
create or replace view public.v_parceiro_a_pagar
with (security_invoker = true) as
select
  g.id as pagamento_id,
  g.parceiro_id,
  p.nome as parceiro_nome,
  p.forma_pagamento,
  g.tipo,
  g.venda_id,
  g.competencia,
  g.valor,
  g.vence_em,
  ((now() at time zone 'America/Sao_Paulo')::date - g.vence_em) as dias_atraso,
  case when g.vence_em = (now() at time zone 'America/Sao_Paulo')::date then 'hoje' else 'atrasado' end as situacao,
  p.pix_chave,
  (p.pix_titular_conferido_em is not null) as pix_titular_conferido,
  (p.pix_titular_conferido_em is not null and p.pix_chave is not null) as pode_pagar
from public.parceiro_pagamentos g
join public.parceiros p on p.id = g.parceiro_id
where g.status = 'previsto' and g.vence_em <= (now() at time zone 'America/Sao_Paulo')::date;

-- ─────────────────────── v_margem_canal ───────────────────────
-- Comissão Nio (prevista/paga) − o que foi pago aos parceiros, por origem. Só a origem parceiro_pap tem custo de parceiro.
create or replace view public.v_margem_canal
with (security_invoker = true) as
with ven as (
  select origem,
         count(*) filter (where status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme')) as vendas,
         coalesce(sum(comissao_prevista) filter (where status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme')), 0) as comissao_nio_prevista,
         coalesce(sum(comissao_paga), 0) as comissao_nio_paga
    from public.vendas group by origem
), par as (
  select 'parceiro_pap'::text as origem,
         coalesce(sum(valor) filter (where status = 'pago'), 0)     as parceiros_pago,
         coalesce(sum(valor) filter (where status = 'previsto'), 0) as parceiros_previsto
    from public.parceiro_pagamentos
)
select
  v.origem,
  v.vendas,
  v.comissao_nio_prevista,
  v.comissao_nio_paga,
  coalesce(p.parceiros_pago, 0)     as parceiros_pago,
  coalesce(p.parceiros_previsto, 0) as parceiros_previsto,
  v.comissao_nio_paga - coalesce(p.parceiros_pago, 0) as margem_paga,
  v.comissao_nio_prevista - coalesce(p.parceiros_pago, 0) - coalesce(p.parceiros_previsto, 0) as margem_prevista
from ven v left join par p on p.origem = v.origem;

grant select on public.v_parceiro_pontos_mes, public.v_parceiro_indicadores, public.v_parceiro_a_pagar, public.v_margem_canal to authenticated;
revoke all on public.v_parceiro_pontos_mes, public.v_parceiro_indicadores, public.v_parceiro_a_pagar, public.v_margem_canal from anon;
