-- id: A6
-- titulo: Cliente pede para parar (SAIR) e nada mais sai
-- tipo: atual
select sim.lead_novo('Bia A6') as c \gset
select sim.cliente_escreve(:'c', 'SAIR') as r1 \gset
select sim.fila_rodar();
select sim.confere('a Mari não respondeu ao SAIR', :'r1' like 'calada%', :'r1');
select sim.confere('ficou marcado Não contatar', (sim.foto(:'c') ->> 'nao_contatar')::boolean);
select sim.cliente_escreve(:'c', 'oi, mudei de ideia') as r2 \gset
select sim.fila_rodar();
select sim.confere('cliente escreve de novo: a Mari continua calada', :'r2' like 'calada%', :'r2');
select sim.passa(:'c', '2 days');
select count(*) as n from sim.cadencia(sim.meio_dia()) x where x like '%enviado' \gset
select sim.confere('a cadência não manda nada', :n = 0, 'envios da cadência: ' || :n);
