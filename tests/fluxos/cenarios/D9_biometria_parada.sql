-- id: D9
-- titulo: Biometria parada: um lembrete em D+1 do link e depois o time liga (nunca automático)
-- tipo: atual
-- sem queda da biometria da Nio no período (a cópia traz as quedas reais; com queda o caminho é o BIOVOLTA)
delete from public.biometria_quedas;
select sim.lead_com_venda('Jair D9') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"aprovado"}');
select public.backoffice_momento(sim.venda(:'c'), 'pedido', jsonb_build_object('pedido', 'P' || sim._conv(:'c'), 'link', 'https://exemplo.test/bio'));
select sim.fila_rodar();
select sim.como('servico');
select count(*) as n0 from sim.cadencia(now()) x where x like 'BIO1%enviado' \gset
select sim.confere('logo depois do pedido o lembrete não sai', :n0 = 0, 'BIO1: ' || :n0);
select sim.passa(:'c', '2 days');
select count(*) from sim.cadencia(sim.meio_dia() + interval '1 day');
select sim.passa(:'c', '1 day');
select count(*) from sim.cadencia(sim.meio_dia() + interval '1 day');
select sim.confere('o lembrete da biometria saiu uma vez só', sim.envios_de(:'c', 'cadencia:BIO1') = 1, 'BIO1: ' || sim.envios_de(:'c', 'cadencia:BIO1'));
select sim.confere('nada mais automático sobre a biometria', (select count(*) from sim.envios where conversa = :'c' and por like 'cadencia:BIO%') = 1,
  (select string_agg(por, ' ') from sim.envios where conversa = :'c' and por like 'cadencia:%'));
