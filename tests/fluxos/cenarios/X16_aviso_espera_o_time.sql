-- id: X16
-- titulo: Caso Lucas (0274): aviso automático da venda (a biometria da Nio voltou) espera 2 h depois de alguém do time falar
-- tipo: atual
select sim.lead_com_venda('Lucas X16') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"aprovado"}');
select sim.fila_rodar();
select sim.como('servico');
update public.vendas set biometria_status = 'pendente', biometria_link_enviado_em = now() - interval '26 hours' where id = sim.venda(:'c');
insert into public.biometria_quedas (inicio, origem, fim, fechada_como) values (now() - interval '20 hours', 'manual', now() - interval '1 hour', 'manual');
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Lucas, a biometria já chegou aí? Qualquer dúvida me chama.');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('o time acabou de falar: o aviso "a biometria voltou" espera', (sim.cadencia_ver(:'c') ->> 'proximo') = 'BIOVOLTA' and coalesce(sim.cadencia_ver(:'c') ->> 'bloqueio', '') like '%time falou%2 h%', sim.cadencia_ver(:'c')::text);
select sim.passa(:'c', '3 hours');
select sim.confere('3 h depois: não é mais a espera do time', coalesce(sim.cadencia_ver(:'c') ->> 'bloqueio', '') not like '%time falou%2 h%', sim.cadencia_ver(:'c')::text);
