-- id: X51
-- titulo: Caso Queroly (19/11, OS 12205921): a Situação do agendamento da Consulta OS vira aviso do dia na Live › Conferir (Atribuído, Em deslocamento, Agendamento Cancelado, Não atribuído só depois da metade do período), "Ciente" esconde até mudar, e "Em deslocamento" avisa o cliente UMA vez (nota + mensagem)
-- tipo: atual
select sim.venda_pronta('Queroly X51') as c \gset
select '97' || sim._conv(:'c') as os \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os', jsonb_build_object('os', :'os', 'forma', 'boleto'));
select public.backoffice_momento(sim.venda(:'c'), 'agendar', jsonb_build_object('dia', (now() at time zone 'America/Sao_Paulo')::date::text, 'periodo', '08:00'));
select sim.fila_rodar();
select to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY') as hoje \gset

-- 1ª leitura: Atribuído, período do dia inteiro → aviso "técnico definido"
select sim._servico();
select public.os_registrar_leitura(:'os', 'operador', jsonb_build_object('status_ordem', 'Em Aprovisionamento',
  'status_agendamento', 'Atribuído', 'agendamento', :'hoje' || ' - 00:00 às 23:59'));
select sim.como('backoffice');
select sim.confere('Atribuído no dia da visita aparece no Conferir (os_agenda · técnico definido)',
  exists (select 1 from jsonb_array_elements(public.live_conferir()) x where x ->> 'tipo' = 'os_agenda' and x ->> 'chave' = :'os'
            and x ->> 'texto' like 'Técnico definido%'), null);

-- Ciente: some
select public.os_agenda_ciente(:'os');
select sim.confere('Ciente esconde o aviso enquanto a Situação não muda',
  not exists (select 1 from jsonb_array_elements(public.live_conferir()) x where x ->> 'tipo' = 'os_agenda' and x ->> 'chave' = :'os'), null);
select sim.confere('o Ciente fica na linha do tempo da venda, com autor',
  exists (select 1 from public.eventos_venda where venda_id = sim.venda(:'c') and tipo = 'os_agenda_ciente' and criado_por is not null), null);

-- Em deslocamento: volta o aviso e o cliente é avisado uma vez
select sim._servico();
select public.os_registrar_leitura(:'os', 'operador', jsonb_build_object('status_ordem', 'Em Aprovisionamento',
  'status_agendamento', 'Em deslocamento', 'agendamento', :'hoje' || ' - 00:00 às 23:59'));
select sim.fila_rodar();
select sim.como('backoffice');
select sim.confere('Em deslocamento volta para o Conferir (técnico a caminho)',
  exists (select 1 from jsonb_array_elements(public.live_conferir()) x where x ->> 'tipo' = 'os_agenda' and x ->> 'chave' = :'os'
            and x ->> 'texto' like '%a caminho%'), null);
select count(*) as n1 from public.chatwoot_acoes where venda_id = sim.venda(:'c') and tipo = 'mensagem'
   and payload ->> 'texto_chave' = 'bo_os_a_caminho' and status <> 'cancelada' \gset
select sim.confere('o cliente recebeu "técnico a caminho" (1 mensagem)', :n1 = 1, :'n1');
select sim.confere('a nota interna diz que o técnico está em deslocamento',
  exists (select 1 from public.chatwoot_acoes where venda_id = sim.venda(:'c') and tipo = 'nota' and payload ->> 'content' like '%deslocamento%'), null);

-- a mesma Situação lida de novo (ou ida e volta) não repete a mensagem
select sim._servico();
select public.os_registrar_leitura(:'os', 'operador', jsonb_build_object('status_ordem', 'Em Aprovisionamento',
  'status_agendamento', 'Atribuído', 'agendamento', :'hoje' || ' - 00:00 às 23:59'));
select public.os_registrar_leitura(:'os', 'operador', jsonb_build_object('status_ordem', 'Em Aprovisionamento',
  'status_agendamento', 'Em deslocamento', 'agendamento', :'hoje' || ' - 00:00 às 23:59'));
select sim.fila_rodar();
select count(*) as n2 from public.chatwoot_acoes where venda_id = sim.venda(:'c') and tipo = 'mensagem'
   and payload ->> 'texto_chave' = 'bo_os_a_caminho' and status <> 'cancelada' \gset
select sim.confere('"técnico a caminho" não repete no mesmo dia', :n2 = 1, :'n2');

-- Não atribuído: antes da metade do período não avisa; depois, avisa
select sim.venda_pronta('Bia X51') as b \gset
select '98' || sim._conv(:'b') as osb \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'b'), 'os', jsonb_build_object('os', :'osb', 'forma', 'boleto'));
select public.backoffice_momento(sim.venda(:'b'), 'agendar', jsonb_build_object('dia', (now() at time zone 'America/Sao_Paulo')::date::text, 'periodo', '08:00'));
select sim.fila_rodar();
select sim._servico();
select public.os_registrar_leitura(:'osb', 'operador', jsonb_build_object('status_ordem', 'Em Aprovisionamento',
  'status_agendamento', 'Não atribuído', 'agendamento', :'hoje' || ' - 23:58 às 23:59'));
select sim.como('backoffice');
select sim.confere('Não atribuído antes da metade do período não vira aviso',
  not exists (select 1 from jsonb_array_elements(public.live_conferir()) x where x ->> 'tipo' = 'os_agenda' and x ->> 'chave' = :'osb'), null);
select sim._servico();
select public.os_registrar_leitura(:'osb', 'operador', jsonb_build_object('status_ordem', 'Em Aprovisionamento',
  'status_agendamento', 'Não atribuído', 'agendamento', :'hoje' || ' - 00:00 às 00:01'));
select sim.como('backoffice');
select sim.confere('Não atribuído depois da metade do período vira aviso (sem técnico)',
  exists (select 1 from jsonb_array_elements(public.live_conferir()) x where x ->> 'tipo' = 'os_agenda' and x ->> 'chave' = :'osb'
            and x ->> 'texto' like 'Ainda sem técnico%'), null);

-- Agendamento Cancelado com a OS em exceção (Pendência Cliente): fica só a linha da exceção; vista a exceção, aparece o aviso
select sim._servico();
select public.os_registrar_leitura(:'osb', 'operador', jsonb_build_object('status_ordem', 'Pendência Cliente',
  'status_agendamento', 'Agendamento Cancelado', 'agendamento', :'hoje' || ' - 00:00 às 00:01'));
select sim.como('backoffice');
select sim.confere('cancelada com exceção aberta: só a linha da exceção',
  exists (select 1 from jsonb_array_elements(public.live_conferir()) x where x ->> 'tipo' = 'os_excecao' and x ->> 'chave' = :'osb')
  and not exists (select 1 from jsonb_array_elements(public.live_conferir()) x where x ->> 'tipo' = 'os_agenda' and x ->> 'chave' = :'osb'), null);
select public.os_excecao_visto(:'osb');
select sim.confere('exceção vista: o aviso da visita cancelada aparece',
  exists (select 1 from jsonb_array_elements(public.live_conferir()) x where x ->> 'tipo' = 'os_agenda' and x ->> 'chave' = :'osb'
            and x ->> 'texto' like '%cancelou a visita%'), null);
select sim.confere('nenhuma mensagem ao cliente na visita cancelada',
  not exists (select 1 from public.chatwoot_acoes where venda_id = sim.venda(:'b') and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_os_a_caminho'), null);

-- vendedor não dá Ciente
select sim.como('vendedor');
select sim.confere('vendedor não marca Ciente', sim.recusa(format('select public.os_agenda_ciente(%L)', :'os')) is not null, null);
