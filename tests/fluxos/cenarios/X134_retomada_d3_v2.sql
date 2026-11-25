-- id: X134
-- titulo: 0405 (Ricardo 25/11): o D3 sai na v2 (estilo Nio) só com ela aprovada e a chave ligada; sem aprovação ou com retomada_d3_v2 = nao, a v1 da 0381; a escada usa a v2; os textos têm linha em branco entre os parágrafos
-- tipo: atual

select sim.lead_novo('Duda X134') as a \gset

-- A) v2 ainda PENDING → v1
select (select tpl from public._retomada_variante((select m from public.mari_conversas m where m.id = :'a'), 'Duda')) as t1 \gset
select sim.confere('v2 pendente → nio_retomada_d3_endereco (v1)', :'t1' = 'nio_retomada_d3_endereco', :'t1');

-- B) v2 aprovada → v2
update public.config_templates_waba set status = 'APPROVED' where nome in ('nio_retomada_d3_endereco_v2', 'nio_retomada_d3_dados_v2');
select (select tpl from public._retomada_variante((select m from public.mari_conversas m where m.id = :'a'), 'Duda')) as t2 \gset
select sim.confere('v2 aprovada → nio_retomada_d3_endereco_v2', :'t2' = 'nio_retomada_d3_endereco_v2', :'t2');

-- C) a escada do D3 manda a v2
select sim.passa(:'a', interval '3 days 2 hours');
select coalesce((select proximo_passo || ':' || coalesce(template, '-') from public.mari_cadencia_avaliar(now(), :'a') limit 1), '?') as tc \gset
select sim.confere('D3 da escada com a v2 aprovada', :'tc' = 'D3:nio_retomada_d3_endereco_v2', :'tc');

-- D) etapa dados → dados_v2; planos sem v2 aprovada → planos (v1)
update public.mari_conversas set cep = '30110000', cidade = 'Belo Horizonte', uf = 'MG', cluster = 'regular', funil_etapa = 'viu_planos' where id = :'a';
select (select tpl from public._retomada_variante((select m from public.mari_conversas m where m.id = :'a'), 'Duda')) as t3 \gset
select sim.confere('planos sem v2 aprovada → v1', :'t3' = 'nio_retomada_d3_planos', :'t3');
update public.mari_conversas set plano_escolhido = 'V-REG-FIBRA' where id = :'a';
select (select tpl from public._retomada_variante((select m from public.mari_conversas m where m.id = :'a'), 'Duda')) as t4 \gset
select sim.confere('dados com v2 aprovada → nio_retomada_d3_dados_v2', :'t4' = 'nio_retomada_d3_dados_v2', :'t4');

-- E) a chave desliga só a v2
update public.config_mari_textos set texto = 'nao' where chave = 'retomada_d3_v2';
select (select tpl from public._retomada_variante((select m from public.mari_conversas m where m.id = :'a'), 'Duda')) as t5 \gset
select sim.confere('retomada_d3_v2 = nao → volta a v1', :'t5' = 'nio_retomada_d3_dados', :'t5');
update public.config_mari_textos set texto = 'sim' where chave = 'retomada_d3_v2';

-- F) espaçamento: todo parágrafo separado por linha em branco; nenhuma tripla quebra
select count(*) as sp from public.config_templates_waba
 where nome like 'nio_retomada_d3_%_v2' and position(E'\n\n' in corpo) > 0 and position(E'\n\n\n' in corpo) = 0
   and (length(corpo) - length(replace(corpo, E'\n\n', ''))) / 2 >= 3 \gset
select sim.confere('espaçamento: as 3 v2 têm ≥ 3 linhas em branco e nenhuma quebra tripla', :sp = 3, :'sp');

update public.config_templates_waba set status = 'PENDING' where nome like 'nio_retomada_d3_%_v2';
