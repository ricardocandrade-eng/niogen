-- id: X149
-- titulo: 0426 (Ricardo, 26/11): lead da Fila Vero que clicou na oferta, recebeu o template da Mari e não escreveu entra na Live 2.0 1 h depois como "Chamar por fora" (janela de 24 h nunca abriu); "Enviei" registra o toque, tira da fila e dá 2 dias; sem resposta → Saída "Sem resposta" automática; Adiar segura a Saída; quem escreve sai do cartão
-- tipo: atual
select sim.como('servico');
insert into sim.cw (conv, telefone, nome) values
  ('994901', '5531999490001', 'Ana X149'), ('994902', '5531999490002', 'Bia X149'),
  ('994903', '5531999490003', 'Caio X149'), ('994904', '5531999490004', 'Duda X149');
insert into public.fila_vero (nome, telefone, segmento, status, template, wamid, codigo)
values ('Ana X149', '5531999490001', 'instalado', 'enviado', 'nio_fv_a1', 'wamid.X149A', 'x149a001'),
       ('Bia X149', '5531999490002', 'instalado', 'enviado', 'nio_fv_a1', 'wamid.X149B', 'x149b002'),
       ('Caio X149', '5531999490003', 'instalado', 'enviado', 'nio_fv_a1', 'wamid.X149C', 'x149c003'),
       ('Duda X149', '5531999490004', 'instalado', 'enviado', 'nio_fv_a1', 'wamid.X149D', 'x149d004');
select (public.fila_vero_clique_resultado((select id from public.fila_vero where codigo = 'x149a001'), true, '994901') ->> 'conversa_id') as a \gset
select (public.fila_vero_clique_resultado((select id from public.fila_vero where codigo = 'x149b002'), true, '994902') ->> 'conversa_id') as b \gset
select (public.fila_vero_clique_resultado((select id from public.fila_vero where codigo = 'x149c003'), true, '994903') ->> 'conversa_id') as c \gset
select (public.fila_vero_clique_resultado((select id from public.fila_vero where codigo = 'x149d004'), true, '994904') ->> 'conversa_id') as d \gset
select sim.fila_rodar();
select sim.confere('o clique abriu o lead e a Mari mandou o template (clique_msg_em gravado)',
  (select clique_msg_em is not null and respondeu_em is null from public.fila_vero where codigo = 'x149a001'),
  (select row(clique_msg_em, respondeu_em)::text from public.fila_vero where codigo = 'x149a001'));

-- 1) antes de 1 h: ainda não é tarefa do time
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select sim.confere('antes de 1 h o lead não entra na fila como "Chamar por fora"',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'a' and x -> 'fontes' ? 'fila_vero:chamar_fora'),
  (select x ->> 'fontes' from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'a'));

-- 2) 1 h depois sem resposta: entra na Live 2.0 com os botões do contato por fora
select sim.como('servico');
select sim.passa(:'a', interval '61 minutes');
select sim.passa(:'b', interval '61 minutes');
select sim.passa(:'c', interval '61 minutes');
select sim.passa(:'d', interval '61 minutes');
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'a'), '{}') as la \gset
select sim.confere('1 h depois o lead está na fila, com a fonte "fila_vero:chamar_fora"',
  (:'la')::jsonb -> 'fontes' ? 'fila_vero:chamar_fora', left(:'la', 400));
select sim.confere('o motivo diz que ele clicou na oferta e não respondeu',
  ((:'la')::jsonb ->> 'oque' || ' ' || coalesce((:'la')::jsonb ->> 'motivos', '')) ~* 'clicou na oferta da Fila Vero',
  (:'la')::jsonb ->> 'oque' || ' · ' || coalesce((:'la')::jsonb ->> 'motivos', ''));
select sim.confere('botão "Abrir WhatsApp" com o telefone do cliente e o texto pronto com o 1º nome',
  exists (select 1 from jsonb_array_elements((:'la')::jsonb -> 'acoes') y
           where y ->> 'a' = 'wa' and y ->> 'tel' = '5531999490001' and y ->> 'texto' like 'Oi, Ana!%'),
  (:'la')::jsonb ->> 'acoes');
select sim.confere('botão "Enviei" chama fila_vero_fora_enviei com a conversa',
  exists (select 1 from jsonb_array_elements((:'la')::jsonb -> 'acoes') y
           where y ->> 'fn' = 'fila_vero_fora_enviei' and y #>> '{args,p_conversa}' = :'a'),
  (:'la')::jsonb ->> 'acoes');
select sim.confere('a linha aceita Adiar e Saída (os botões fixos da Live 2.0)',
  ((:'la')::jsonb ->> 'pode_adiar')::boolean and ((:'la')::jsonb ->> 'pode_sair')::boolean,
  (:'la')::jsonb ->> 'pode_adiar' || ' · ' || ((:'la')::jsonb ->> 'pode_sair'));

-- 3) Enviei: grava o toque, sai da fila e fica "em pausa" no radar
select (public.fila_vero_fora_enviei(:'a') ->> 'ok') as ok \gset
select sim.confere('Enviei devolve ok e grava fora_enviado_em na linha da Fila Vero',
  :'ok' = 'true' and (select fora_enviado_em is not null and fora_por is not null from public.fila_vero where codigo = 'x149a001'), :'ok');
select sim.confere('o toque ficou no histórico de contatos (WhatsApp, saída, FV_FORA)',
  exists (select 1 from public.contatos_cliente k where k.conversa_id = :'a' and k.toque = 'FV_FORA' and k.canal = 'whatsapp' and k.direcao = 'saida'),
  (select string_agg(toque, ', ') from public.contatos_cliente where conversa_id = :'a'));
select sim.confere('e ficou a linha de sistema na conversa',
  exists (select 1 from public.mari_turnos t where t.conversa_id = :'a' and t.papel = 'sistema' and t.texto like '[Fila Vero: contato por fora%'), null);
select public.live2_fila()::text as f \gset
select sim.confere('depois do Enviei o lead sai da fila',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'a'),
  (select x ->> 'oque' from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'a'));
select sim.confere('e aparece no radar "em pausa", com a hora de volta',
  exists (select 1 from jsonb_array_elements((:'f')::jsonb #> '{radar,em_pausa}') x where x ->> 'k' = 'c:' || :'a' and x ->> 'volta_em' is not null),
  (:'f')::jsonb #>> '{radar,em_pausa}');
select sim.confere('Enviei de novo é recusado (o contato por fora é um só)',
  sim.recusa(format('select public.fila_vero_fora_enviei(%L)', :'a')) is not null, sim.recusa(format('select public.fila_vero_fora_enviei(%L)', :'a')));
select sim.como('vendedor');
select sim.confere('quem não é do backoffice não registra o Enviei',
  sim.recusa(format('select public.fila_vero_fora_enviei(%L)', :'b')) is not null, sim.recusa(format('select public.fila_vero_fora_enviei(%L)', :'b')));

-- 4) o relógio da Saída: 2 dias depois do Enviei (não do clique)
select sim.como('servico');
select sim.passa(:'a', interval '47 hours');
select public.fila_vero_clique_encerrar();
select sim.confere('47 h depois do Enviei (mais de 2 dias do clique) o lead ainda está vivo',
  (select coalesce(funil_destino, 'em_andamento') = 'em_andamento' from public.mari_conversas where id = :'a'),
  (select funil_destino from public.mari_conversas where id = :'a'));
select sim.passa(:'a', interval '2 hours');
select public.fila_vero_clique_encerrar();
select sim.confere('2 dias depois do Enviei, sem resposta → Saída automática',
  (select coalesce(funil_destino, 'em_andamento') <> 'em_andamento' from public.mari_conversas where id = :'a'),
  (select funil_destino from public.mari_conversas where id = :'a'));
select sim.confere('e a linha da Fila Vero ficou encerrada',
  (select status = 'encerrado' from public.fila_vero where codigo = 'x149a001'), (select status from public.fila_vero where codigo = 'x149a001'));

-- 5) ninguém clicou em nada: 2 dias depois do template da Mari a Saída automática continua valendo (0285)
select sim.passa(:'b', interval '2 days');
select public.fila_vero_clique_encerrar();
select sim.confere('sem Enviei e sem Adiar: Saída automática 2 dias depois do template',
  (select coalesce(funil_destino, 'em_andamento') <> 'em_andamento' from public.mari_conversas where id = :'b'),
  (select funil_destino from public.mari_conversas where id = :'b'));

-- 6) Adiar: sai da fila e a Saída automática espera a data
select sim.como('backoffice');
select public.backoffice_conversa_espera(:'c', (current_date + 5), 'Chamar na semana que vem');
select public.live2_fila()::text as f \gset
select sim.confere('adiado: o cartão "Chamar por fora" sai da fila',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'c' and x -> 'fontes' ? 'fila_vero:chamar_fora'),
  (select x ->> 'fontes' from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'c'));
select sim.como('servico');
select sim.passa(:'c', interval '3 days');
select public.fila_vero_clique_encerrar();
select sim.confere('adiado: a Saída automática não leva o lead antes da data',
  (select coalesce(funil_destino, 'em_andamento') = 'em_andamento' from public.mari_conversas where id = :'c'),
  (select funil_destino from public.mari_conversas where id = :'c'));

-- 7) o cliente escreveu para a Mari: deixa de ser "Chamar por fora"
select sim.cliente_escreve(:'d', 'Oi, quero saber da internet', false);
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select sim.confere('cliente escreveu → o cartão "Chamar por fora" some',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'d' and x -> 'fontes' ? 'fila_vero:chamar_fora'),
  (select x ->> 'fontes' from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'d'));
select sim.confere('e o Enviei é recusado para quem já respondeu',
  sim.recusa(format('select public.fila_vero_fora_enviei(%L)', :'d')) is not null, sim.recusa(format('select public.fila_vero_fora_enviei(%L)', :'d')));
