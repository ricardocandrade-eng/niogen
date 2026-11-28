-- NIOGEN | supabase/migrations/0440_retrato_comissao_por_plano.sql | 28/11/2026 — Claude Code (Fable 5.2)
-- Pendência "Comissão por plano no retrato do agente de tráfego (base do CAC)" — auditoria de 25/11, §4.5 e §5.3: o retrato
-- traz o custo por venda e por instalada, mas não o que cada venda paga; o agente media contra um alvo de custo sem saber
-- que o plano mais vendido paga R$ 350.
-- O que muda: agente_trafego_retrato() ganha a chave "comissao":
--   por_plano         código do plano → nome, cluster e comissão de tabela (config_planos, só os ativos);
--   meta_vendas_os    das conversas com origem meta_ads na janela que viraram venda com OS: quantas, quantas com plano
--                     reconhecido, soma e média da comissão de tabela, e por plano;
--   meta_instaladas   o mesmo recorte para as instaladas;
--   margem_por_venda_os / margem_por_instalada   comissão média − custo_por (gasto da Meta ÷ marcos), quando os dois existem;
--   nota              o que o número é e o que não é.
-- A comissão é a de TABELA do plano escolhido na conversa (config_planos.comissao): não inclui bônus de transição, NMEI nem
-- M-10, e não desconta estorno. Só contagens e valores de tabela: nenhum dado de cliente (a privacidade do retrato não muda).
-- Regra 20: só leitura — nenhum estado, vez, prazo, evento ou tabela nova; conferência: sem item novo. Regra 15: os valores
-- vêm da config, nada fixo. Regra 19: uma leitura de config_planos (23 linhas) e duas agregações sobre a base que a função já
-- monta; medir na cópia antes e depois. Remendo da versão no ar. Cenário X162.
begin;

do $mig$
declare
  d      text := pg_get_functiondef('public.agente_trafego_retrato(integer)'::regprocedure);
  ponto  text := E'(\\r?\\n)(    ''custo_por'', jsonb_build_object\\()';
  novo   text := $novo$
    'comissao', jsonb_build_object(
      'por_plano', (select coalesce(jsonb_object_agg(p.codigo, jsonb_build_object('nome', coalesce(p.nome_curto, p.nome), 'cluster', p.cluster, 'comissao', p.comissao)), '{}'::jsonb)
                      from public.config_planos p where p.ativo and p.codigo is not null),
      'meta_vendas_os', (select jsonb_build_object('vendas', count(*), 'com_plano', count(p.codigo),
                                'comissao_soma', coalesce(sum(p.comissao), 0), 'comissao_media', round(avg(p.comissao), 2),
                                'por_plano', public._agente_trafego_contar(array_agg(b.plano)))
                           from base b left join public.config_planos p on p.codigo = b.plano
                          where b.origem = 'meta_ads' and b.venda_os),
      'meta_instaladas', (select jsonb_build_object('vendas', count(*), 'com_plano', count(p.codigo),
                                 'comissao_soma', coalesce(sum(p.comissao), 0), 'comissao_media', round(avg(p.comissao), 2),
                                 'por_plano', public._agente_trafego_contar(array_agg(b.plano)))
                            from base b left join public.config_planos p on p.codigo = b.plano
                           where b.origem = 'meta_ads' and b.instalada),
      'margem_por_venda_os', (select case when (fm.funil ->> 'vendas_os')::int > 0 and avg(p.comissao) is not null
                                          then round(avg(p.comissao) - mt.gasto / (fm.funil ->> 'vendas_os')::int, 2) end
                                from base b join public.config_planos p on p.codigo = b.plano
                               where b.origem = 'meta_ads' and b.venda_os),
      'margem_por_instalada', (select case when (fm.funil ->> 'instaladas')::int > 0 and avg(p.comissao) is not null
                                           then round(avg(p.comissao) - mt.gasto / (fm.funil ->> 'instaladas')::int, 2) end
                                 from base b join public.config_planos p on p.codigo = b.plano
                                where b.origem = 'meta_ads' and b.instalada),
      'nota', 'comissao (0440): comissão de TABELA do plano escolhido na conversa (config_planos), em R$. Não inclui bônus de transição, NMEI nem M-10 e não desconta estorno. margem = comissão média − custo_por do mesmo marco (só mídia da Meta; sem custo de equipe e ferramentas). Use para comparar o custo por venda com o que a venda paga, por plano.'),$novo$;
begin
  if position($a$'comissao', jsonb_build_object($a$ in d) > 0 then
    return;   -- já remendada
  end if;
  if regexp_count(d, ponto) <> 1 then
    raise exception '0440: não achei (ou achei mais de uma vez) o ponto de encaixe em agente_trafego_retrato';
  end if;
  execute regexp_replace(d, ponto, replace(replace(novo, E'\\', E'\\\\'), '&', E'\\&') || E'\\1\\2');
end $mig$;

commit;
