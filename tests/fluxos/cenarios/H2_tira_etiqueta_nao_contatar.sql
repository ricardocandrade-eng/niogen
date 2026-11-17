-- id: H2
-- titulo: Alguém tira a etiqueta nao-contatar à mão no Chatwoot
-- tipo: atual
select sim.lead_novo('Sara H2') as c \gset
select sim.cliente_escreve(:'c', 'PARAR');
select sim.fila_rodar();
select sim.time_no_chatwoot(:'c', '{"remove":["nao-contatar"]}');
select sim.fila_rodar();
select sim.confere('o NIOGEN continua com Não contatar', (sim.foto(:'c') ->> 'nao_contatar')::boolean);
select sim.cliente_escreve(:'c', 'oi') as r \gset
select sim.confere('a Mari continua calada', :'r' like 'calada%', :'r');
select sim.passa(:'c', '2 days');
select count(*) as n from sim.cadencia(sim.meio_dia()) x where x like '%enviado' \gset
select sim.confere('a cadência não manda nada', :n = 0, 'envios: ' || :n);
