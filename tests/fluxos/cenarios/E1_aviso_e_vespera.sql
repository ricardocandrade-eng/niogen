-- id: E1
-- titulo: Instalação agendada: o aviso sai uma vez e a véspera sai uma vez, mesmo com o time na conversa
-- tipo: atual
select sim.venda_pronta('Nei E1') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '91' || sim._conv(:'c'), 'dia', (current_date + 3)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.como('servico');
select count(*) from sim.cadencia(sim.meio_dia());
select count(*) from sim.cadencia(sim.meio_dia());
select sim.fila_rodar();   -- 0366: o alerta de golpe sai logo depois da confirmação da instalação (a fila roda a cada minuto)
select sim.confere('o aviso da instalação saiu uma vez', sim.envios_de(:'c', 'cadencia:INSTALACAO') = 1, 'INSTALACAO: ' || sim.envios_de(:'c', 'cadencia:INSTALACAO'));
select sim.passa(:'c', '2 days');
select sim.tique();
select count(*) from sim.cadencia(sim.meio_dia());
select count(*) from sim.cadencia(sim.meio_dia() + interval '2 hours');
select sim.confere('a véspera saiu uma vez', sim.envios_de(:'c', 'cadencia:VESPERA') = 1, 'VESPERA: ' || sim.envios_de(:'c', 'cadencia:VESPERA'));
