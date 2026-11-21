-- id: X70
-- titulo: Caso L-217 (Jussara, OS 12242686, 19/11): a agenda gravada à mão ficou "tarde" e a Consulta OS leu 08:00 às 12:00 no MESMO dia — a janela da Nio corrige o horário e o turno da venda (antes só corrigia se a data mudasse); janela do dia inteiro não mexe
-- tipo: atual
select sim.venda_pronta('Jussara X70') as c \gset
select '98' || sim._conv(:'c') as os \gset
select ((now() at time zone 'America/Sao_Paulo')::date + 1)::text as dia \gset
select to_char((now() at time zone 'America/Sao_Paulo')::date + 1, 'DD/MM/YYYY') as dia_br \gset

-- o time grava a OS com o dia à mão e o período que o campo trazia pronto (tarde)
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar',
  jsonb_build_object('os', :'os', 'dia', :'dia', 'periodo', '13:00', 'forma', 'boleto', 'sem_aviso', true));
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('a venda ficou com a tarde gravada à mão (o erro do caso)',
  (select instalacao_turno from public.vendas where id = sim.venda(:'c')) = 'tarde',
  (select coalesce(instalacao_turno, '—') from public.vendas where id = sim.venda(:'c')));

-- a Consulta OS lê o mesmo dia com a janela da manhã
select sim._servico();
select public.os_registrar_leitura(:'os', 'operador', jsonb_build_object('status_ordem', 'Em Aprovisionamento',
  'status_agendamento', 'Atribuído', 'agendamento', :'dia_br' || ' - 08:00 às 12:00'));
select sim.como('servico');
select sim.confere('a janela da Nio vence: turno da venda vira manhã',
  (select instalacao_turno from public.vendas where id = sim.venda(:'c')) = 'manha',
  (select coalesce(instalacao_turno, '—') from public.vendas where id = sim.venda(:'c')));
select sim.confere('o horário da venda vira 08:00 do mesmo dia (Brasília)',
  (select to_char(instalacao_agendada_para at time zone 'America/Sao_Paulo', 'YYYY-MM-DD HH24:MI') from public.vendas where id = sim.venda(:'c'))
    = :'dia' || ' 08:00',
  (select to_char(instalacao_agendada_para at time zone 'America/Sao_Paulo', 'YYYY-MM-DD HH24:MI') from public.vendas where id = sim.venda(:'c')));
select sim.confere('a correção fica na linha do tempo da venda (os_agendamento, de → para, janela)',
  exists (select 1 from public.eventos_venda where venda_id = sim.venda(:'c') and tipo = 'os_agendamento'
            and detalhe ->> 'janela' = '08:00 - 12:00'), null);

-- a mesma leitura de novo não repete o evento
select count(*) as n1 from public.eventos_venda where venda_id = sim.venda(:'c') and tipo = 'os_agendamento' \gset
select sim._servico();
select public.os_registrar_leitura(:'os', 'operador', jsonb_build_object('status_ordem', 'Em Aprovisionamento',
  'status_agendamento', 'Em execução', 'agendamento', :'dia_br' || ' - 08:00 às 12:00'));
select sim.confere('leitura igual não grava a correção de novo',
  (select count(*) from public.eventos_venda where venda_id = sim.venda(:'c') and tipo = 'os_agendamento') = :n1, null);

-- janela do dia inteiro (00:00 às 23:59) não é período: não mexe no horário nem no turno
select sim.venda_pronta('Davi X70') as c2 \gset
select '98' || sim._conv(:'c2') as os2 \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c2'), 'os_agendar',
  jsonb_build_object('os', :'os2', 'dia', :'dia', 'periodo', '13:00', 'forma', 'boleto', 'sem_aviso', true));
select sim.fila_rodar();
select sim._servico();
select public.os_registrar_leitura(:'os2', 'operador', jsonb_build_object('status_ordem', 'Em Aprovisionamento',
  'status_agendamento', 'Atribuído', 'agendamento', :'dia_br' || ' - 00:00 às 23:59'));
select sim.como('servico');
select sim.confere('janela do dia inteiro: a tarde gravada fica',
  (select instalacao_turno from public.vendas where id = sim.venda(:'c2')) = 'tarde'
  and (select to_char(instalacao_agendada_para at time zone 'America/Sao_Paulo', 'HH24:MI') from public.vendas where id = sim.venda(:'c2')) = '13:00',
  (select coalesce(instalacao_turno, '—') || ' ' || to_char(instalacao_agendada_para at time zone 'America/Sao_Paulo', 'HH24:MI') from public.vendas where id = sim.venda(:'c2')));
