-- id: X91
-- titulo: 0365 (23/11): venda que segue no funil com o lead já em Saída acende "falha" na Conferência; com o lead de volta, apaga
-- tipo: atual
select sim.venda_pronta('Ricardo X91') as c \gset
select sim.como('servico');
select coalesce(nullif(btrim(cliente_nome), ''), 'sem nome') as nome from public.vendas where id = sim.venda(:'c') \gset
select x ->> 'texto' as t0 from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'venda_viva_lead_saida' \gset
select sim.confere('venda em andamento com o lead em andamento: não acusa', :'t0' not like ('%' || :'nome' || '%'), :'t0');

-- o caso de 22/11: a situação gravada do lead é Saída (teste ou duplicada) e a venda segue viva
-- (aqui a situação é gravada à mão para reproduzir o estado; no fim volta ao que era, para as regras gerais)
select situacao as sit0 from public.lead_estado where conversa_id = :'c' \gset
update public.lead_estado set situacao = 'saida_definitiva' where conversa_id = :'c';
select x ->> 'nivel' as n1, x ->> 'texto' as t1 from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'venda_viva_lead_saida' \gset
select sim.confere('lead em Saída e venda viva: acusa (falha) com o nome', :'n1' = 'falha' and :'t1' like ('%' || :'nome' || '%'), :'n1' || ' · ' || :'t1');

update public.lead_estado set situacao = :'sit0' where conversa_id = :'c';
select x ->> 'texto' as t2 from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'venda_viva_lead_saida' \gset
select sim.confere('com o lead de volta ao andamento: não acusa mais', :'t2' not like ('%' || :'nome' || '%'), :'t2');
