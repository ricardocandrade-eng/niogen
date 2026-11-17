-- id: D14
-- titulo: Reagendar para o mesmo dia não repete a mensagem ao cliente
-- tipo: atual
select sim.lead_com_venda('Wal D14') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"aprovado"}');
select public.backoffice_momento(sim.venda(:'c'), 'biometria', '{"resultado":"validada"}');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '97' || sim._conv(:'c'), 'dia', (current_date + 4)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select count(*) as antes from sim.envios where conversa = :'c' and por <> 'mari' \gset
select public.backoffice_momento(sim.venda(:'c'), 'reagendar', jsonb_build_object('dia', (current_date + 4)::text, 'periodo', '08:00'));
select sim.fila_rodar();
select public.backoffice_momento(sim.venda(:'c'), 'reagendar', jsonb_build_object('dia', (current_date + 4)::text, 'periodo', '08:00'));
select sim.fila_rodar();
select sim.confere('reagendar para o mesmo dia e turno não manda mensagem nova',
  (select count(*) from sim.envios where conversa = :'c' and por <> 'mari') = :antes,
  (select (count(*) - :antes) || ' mensagens a mais ao cliente' from sim.envios where conversa = :'c' and por <> 'mari'));
