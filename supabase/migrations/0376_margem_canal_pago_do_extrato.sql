-- NIOGEN | supabase/migrations/0376_margem_canal_pago_do_extrato.sql | 24/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 24/11: "Sim, corrigir" — o bloco "Margem por canal" da Conciliação mostrava "Comissão Nio paga R$ 0" em todos os canais,
-- mesmo com o 1º extrato importado (1QNOV26, R$ 380 da venda da OS 12096096).
-- Causa: v_margem_canal somava vendas.comissao_paga, coluna que ninguém escreve desde a razão da comissão (0158). O dinheiro da Nio
-- está em comissao_lancamentos (origem 'extrato': comissão, bônus, estorno e multa) — a mesma fonte do "Pago pela Nio" da tela.
-- Agora: comissão Nio paga = soma das linhas do extrato ligadas às vendas do canal. Linha da Nio sem venda no NIOGEN não tem canal:
-- fica fora daqui (aparece na Conciliação como "Extra da Nio"). Mesmas colunas e tipos da view anterior (a tela não muda).
-- Regra 20: (1)–(3) só leitura, sem estado · (4) dinheiro = o extrato da Nio · (5) sem número novo: a conferência 32 já confere o
-- extrato contra o pedido.
begin;

create or replace view public.v_margem_canal with (security_invoker = true) as
with ext as (
  select l.venda_id, sum(l.valor) as pago
    from public.comissao_lancamentos l
   where l.origem = 'extrato' and l.venda_id is not null
   group by l.venda_id
), ven as (
  select v.origem,
         count(*) filter (where v.status = any (array['1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme'])) as vendas,
         coalesce(sum(v.comissao_prevista) filter (where v.status = any (array['1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme'])), 0::numeric) as comissao_nio_prevista,
         coalesce(sum(e.pago), 0::numeric) as comissao_nio_paga
    from public.vendas v
    left join ext e on e.venda_id = v.id
   group by v.origem
), par as (
  select 'parceiro_pap'::text as origem,
         coalesce(sum(pp.valor) filter (where pp.status = 'pago'), 0::numeric) as parceiros_pago,
         coalesce(sum(pp.valor) filter (where pp.status = 'previsto'), 0::numeric) as parceiros_previsto
    from public.parceiro_pagamentos pp
)
select v.origem,
       v.vendas,
       v.comissao_nio_prevista,
       v.comissao_nio_paga,
       coalesce(p.parceiros_pago, 0::numeric) as parceiros_pago,
       coalesce(p.parceiros_previsto, 0::numeric) as parceiros_previsto,
       v.comissao_nio_paga - coalesce(p.parceiros_pago, 0::numeric) as margem_paga,
       v.comissao_nio_prevista - coalesce(p.parceiros_pago, 0::numeric) - coalesce(p.parceiros_previsto, 0::numeric) as margem_prevista
  from ven v
  left join par p on p.origem = v.origem;
comment on view public.v_margem_canal is
  'Margem por canal (0376): comissão Nio prevista (vendas) e paga (linhas do extrato na razão comissao_lancamentos) × pago/previsto a parceiros.';

commit;
