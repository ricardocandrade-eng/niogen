-- NIOGEN | supabase/migrations/0377_conciliacao_plano_e_datas.sql | 24/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 24/11: "Indicar também o nome do plano vendido, data da venda e data da instalação" (lista "Linha a linha" da Conciliação).
-- v_conciliacao (0371) ganha, NO FIM, plano_nome (config_planos.nome_curto ou nome), vendido_em e instalado_em. Nada mais muda.
-- Regra 20: só leitura, sem estado novo; a conferência 32 continua conferindo o extrato.
begin;

create or replace view public.v_conciliacao with (security_invoker = true) as
with prev as (
  select venda_id, ciclo, sum(valor) as prevista
    from public.comissao_lancamentos
   where origem = 'sistema' and tipo in ('prevista', 'bonus_previsto') and venda_id is not null
   group by 1, 2
), ext as (
  select coalesce(venda_id::text, 'c:' || coalesce(chave_nio ->> 'contrato', chave_nio ->> 'os', id::text)) as k,
         venda_id, ciclo, sum(valor) as paga,
         max(chave_nio ->> 'contrato') as contrato, max(chave_nio ->> 'os') as os, min(data_ref) as data_atv,
         jsonb_agg(jsonb_build_object('evento', chave_nio ->> 'evento', 'sub_evento', chave_nio ->> 'sub_evento', 'comissao', valor,
                     'produto', chave_nio ->> 'produto', 'oferta', chave_nio ->> 'oferta', 'recompra', tipo = 'multa',
                     'data_atv', data_ref, 'tipo', tipo) order by (chave_nio ->> 'linha')::int) as linhas
    from public.comissao_lancamentos
   where origem = 'extrato'
   group by 1, 2, 3
), j as (
  select coalesce(p.ciclo, e.ciclo) as ciclo, coalesce(p.venda_id, e.venda_id) as venda_id, e.k,
         p.prevista, e.paga, e.linhas, e.contrato, e.os, e.data_atv
    from prev p full join ext e on e.venda_id = p.venda_id and e.ciclo = p.ciclo
)
select j.ciclo || '|' || coalesce(j.venda_id::text, j.k)                    as chave,
       j.ciclo, j.venda_id, v.cliente_nome,
       coalesce(v.nio_os, v.nio_pedido, j.os)                                as nio_pedido,
       coalesce(v.nio_contrato, j.contrato)                                  as nio_contrato,
       u.nome                                                                as vendedor_nome,
       coalesce(v.ativado_em, v.instalado_em)                                as ativado_em,
       j.prevista,
       case when j.prevista is not null then v.comissao_nominal end          as comissao_nominal,
       case when j.prevista is not null then v.comissao_adicionais end       as comissao_adicionais,
       case when j.prevista is not null then v.bonus_transicao_previsto end  as bonus_transicao_previsto,
       case when j.prevista is not null then v.bonus_nmei_previsto end       as bonus_nmei_previsto,
       coalesce(j.linhas, '[]'::jsonb)                                       as linhas,
       j.paga,
       coalesce((coalesce(v.ativado_em, v.instalado_em) at time zone 'America/Sao_Paulo')::date, j.data_atv) as fato_gerador,
       v.cancelada_apos_instalar_em,
       (select jsonb_build_object('id', c.id, 'aberta_em', c.aberta_em, 'motivo', c.motivo, 'descricao', c.descricao, 'valor', c.valor,
                                  'status', c.status, 'prazo_em', c.prazo_em, 'resposta', c.resposta)
          from public.nio_contestacoes c
         where c.ciclo = j.ciclo and c.status <> 'cancelada'
           and ((j.venda_id is not null and c.venda_id = j.venda_id) or (j.venda_id is null and c.nio_contrato = j.contrato))
         order by c.aberta_em desc limit 1)                                  as contestacao,
       -- 0377: o que foi vendido e quando (colunas novas no fim)
       coalesce(pl.nome_curto, pl.nome)                                      as plano_nome,
       v.vendido_em,
       v.instalado_em
  from j
  left join public.vendas v on v.id = j.venda_id
  left join public.usuarios u on u.id = v.vendedor_id
  left join public.config_planos pl on pl.id = v.plano_id;
revoke all on public.v_conciliacao from anon;
grant select on public.v_conciliacao to authenticated, service_role;

commit;
