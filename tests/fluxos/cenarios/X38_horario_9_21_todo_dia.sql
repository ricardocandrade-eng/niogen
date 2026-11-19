-- id: X38
-- titulo: Horário do contrato (0304): toques da Mari, Fila Vero e time das 9h às 21h, de segunda a domingo — nem 22h, nem 8h; sábado e domingo iguais aos dias úteis
-- tipo: atual
-- Ricardo, 18/11 (D3 da Retomada saiu às 22h): "Horário do contrato: 9–21 seg–dom" · "Fila Vero e o horário do time passam a seguir
-- o mesmo 9h às 21h todos os dias. Pode aplicar". Datas: 21/11/2026 = sábado, 22/11/2026 = domingo, 23/11/2026 = segunda.
select sim.como('servico');
-- toques automáticos da Mari (cadência, Retomada, véspera, fila do NIOGEN)
select sim.confere('toque da Mari: 22h de quarta não sai (o D3 de 18/11)', not public.mari_no_horario('2026-11-18 22:00-03'::timestamptz, null), 'saiu');
select sim.confere('toque da Mari: 8h30 não sai', not public.mari_no_horario('2026-11-23 08:30-03'::timestamptz, null), 'saiu');
select sim.confere('toque da Mari: 9h e 20h59 saem', public.mari_no_horario('2026-11-23 09:00-03'::timestamptz, null)
  and public.mari_no_horario('2026-11-23 20:59-03'::timestamptz, null), 'não saiu');
select sim.confere('toque da Mari: sábado 18h sai', public.mari_no_horario('2026-11-21 18:00-03'::timestamptz, null), 'não saiu');
select sim.confere('toque da Mari: domingo 10h sai, domingo 21h30 não', public.mari_no_horario('2026-11-22 10:00-03'::timestamptz, null)
  and not public.mari_no_horario('2026-11-22 21:30-03'::timestamptz, null), 'errado');
-- Fila Vero
select sim.confere('Fila Vero: sábado 18h dispara', public.fila_vero_dentro_horario('2026-11-21 18:00-03'::timestamptz), 'parada');
select sim.confere('Fila Vero: domingo 10h dispara', public.fila_vero_dentro_horario('2026-11-22 10:00-03'::timestamptz), 'parada');
select sim.confere('Fila Vero: 21h30 e 8h30 não disparam', not public.fila_vero_dentro_horario('2026-11-22 21:30-03'::timestamptz)
  and not public.fila_vero_dentro_horario('2026-11-23 08:30-03'::timestamptz), 'disparou');
select sim.confere('Fila Vero: feriado continua parado (20/11)', not public.fila_vero_dentro_horario('2026-11-20 10:00-03'::timestamptz), 'disparou');
-- horário do time (prazo do consultor, minutos úteis, horas úteis da Retomada)
select sim.confere('time: sábado 18h e domingo 10h são horário de atendimento', public.mari_atendimento_no_horario('2026-11-21 18:00-03'::timestamptz, null)
  and public.mari_atendimento_no_horario('2026-11-22 10:00-03'::timestamptz, null), 'fora');
select sim.confere('time: domingo 21h30 é fora do horário', not public.mari_atendimento_no_horario('2026-11-22 21:30-03'::timestamptz, null), 'dentro');
select sim.confere('time: domingo 9h–10h conta 60 minutos úteis',
  public.minutos_uteis('2026-11-22 09:00-03'::timestamptz, '2026-11-22 10:00-03'::timestamptz, null) = 60,
  public.minutos_uteis('2026-11-22 09:00-03'::timestamptz, '2026-11-22 10:00-03'::timestamptz, null)::text);
select sim.confere('time: de sábado 9h a domingo 21h são 24 horas úteis',
  public._horas_uteis('2026-11-21 09:00-03'::timestamptz, '2026-11-22 21:00-03'::timestamptz) = 24,
  public._horas_uteis('2026-11-21 09:00-03'::timestamptz, '2026-11-22 21:00-03'::timestamptz)::text);
