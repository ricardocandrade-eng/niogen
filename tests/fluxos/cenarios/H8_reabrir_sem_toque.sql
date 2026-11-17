-- id: H8
-- titulo: Reabrir um lead em Saída: a cadência não dispara um toque atrasado na hora
-- tipo: atual
select sim.lead_novo('Gabi H8') as c \gset
select sim.como('backoffice');
select public.lead_sair(:'c', null, 'recusou', 'preco');
select sim.fila_rodar();
select sim.como('servico');
select sim.passa(:'c', '10 days');
select sim.como('backoffice');
select public.lead_reabrir(:'c', null);
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('reabriu: em andamento', sim.lead_de(:'c') ->> 'destino' = 'em_andamento', sim.lead_de(:'c')::text);
select count(*) as n from sim.cadencia(greatest(now() + interval '5 minutes', sim.hora('10:00'))) x where x like '%enviado' \gset
select sim.confere('nenhum toque sai logo depois de reabrir', :n = 0, 'envios: ' || :n);
