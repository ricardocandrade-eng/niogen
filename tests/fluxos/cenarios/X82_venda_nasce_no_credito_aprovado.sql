-- id: X82
-- titulo: Caso L-219 (22/11): lead conduzido pelo time com crédito aprovado ficava "lead" até alguém lembrar do Virar venda, e aviso, biometria e OS não tinham onde gravar — agora a venda nasce sozinha quando o crédito aprovado é gravado (ou quando o time assume um lead já consultado), mesmo sem plano e sem o nome do titular; a OS espera o plano; a extensão completa a venda com o que está no portal; com a Mari atendendo, "já cliente" ou duplicidade nada muda
-- tipo: atual

-- (a) o time conduz e grava o crédito aprovado na ficha: a venda nasce na hora
select sim.lead_pronto('Auto X82') as a \gset
select sim.time_no_chatwoot(:'a', '{"agente":"Atendente"}');
select sim.time_fala_no_chatwoot(:'a', 'Oi, sou do time. Vou rodar seu crédito.');
select sim.como('backoffice');
select public.lead_registrar_consulta(:'a', 'credito', 'aprovado_todas');
select sim.fila_rodar();
select sim.confere('crédito aprovado com o time: a venda nasceu sozinha', sim.venda(:'a') is not null, null);
select sim.confere('a venda nasceu com o crédito aprovado e o evento de origem',
  (select credito_resultado from public.vendas where id = sim.venda(:'a')) = 'aprovado'
  and exists (select 1 from public.eventos_venda where venda_id = sim.venda(:'a') and tipo = 'venda_automatica_credito'),
  (select coalesce(credito_resultado, '—') from public.vendas where id = sim.venda(:'a')));
select sim.confere('a vez é do time e a pessoa continua dona da conversa',
  sim.lead_de(:'a') ->> 'vez' = 'time' and sim.lead_de(:'a') ->> 'destino' = 'em_andamento' and sim.cw_de(:'a') ->> 'agente' is not null, sim.lead_de(:'a')::text);
select sim.confere('uma venda só para este lead', (select count(*) from public.vendas where origem_ref = 'mari:' || :'a') = 1, null);

-- (b) lead que o time conduziu sem a Mari coletar nada: sem plano, sem nome do titular, elegibilidade vazia (como o L-219)
select sim.lead_pronto('Inc X82') as b \gset
select sim._servico();
update public.mari_conversas set elegibilidade = null, plano_escolhido = null, forma_pagamento = null, complemento = null,
       dados = dados - 'nome' - 'referencia' where id = :'b';
select sim.time_no_chatwoot(:'b', '{"agente":"Atendente"}');
select sim.time_fala_no_chatwoot(:'b', 'Oi, sou do time. Me passa seu CPF?');
select sim.como('backoffice');
select public.lead_registrar_consulta(:'b', 'credito', 'aprovado_todas');
select sim.fila_rodar();
select sim.confere('lead incompleto: a venda nasce mesmo assim, sem plano', sim.venda(:'b') is not null
  and (select plano_id is null from public.vendas where id = sim.venda(:'b')), null);
select sim.confere('o nome da venda é o provisório (o do WhatsApp) e a conversa diz o que falta',
  (select coalesce(btrim(cliente_nome), '') <> '' from public.vendas where id = sim.venda(:'b'))
  and exists (select 1 from public.mari_turnos where conversa_id = :'b' and papel = 'sistema' and texto like '[venda aberta sozinha%falta gravar na venda: plano, nome completo do titular, forma de pagamento%'),
  (select cliente_nome from public.vendas where id = sim.venda(:'b')));
select sim.confere('a elegibilidade vazia virou "ok" (crédito aprovado no portal)', (select elegibilidade from public.mari_conversas where id = :'b') = 'ok', null);

-- a biometria aprova (GED360) e a OS ainda NÃO grava: falta o plano
select public._so_digitos(cliente_cpf_cnpj) as cpfb from public.vendas where id = sim.venda(:'b') \gset
select to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') as agora \gset
select sim._servico();
select public.ged360_registrar(jsonb_build_array(jsonb_build_object('protocolo', 'X82B' || sim._conv(:'b'), 'cpf_cnpj', :'cpfb',
  'data_envio', :'agora', 'tipo_servico', 'BIOMETRIA', 'resultado', 'DOC. APTO PARA VENDA')));
select sim.fila_rodar();
select sim.confere('biometria validada na venda automática', (select biometria_status from public.vendas where id = sim.venda(:'b')) = 'validada',
  (select biometria_status from public.vendas where id = sim.venda(:'b')));
select sim.como('backoffice');
select coalesce(sim.recusa(format($q$select public.backoffice_momento(%L, 'os_agendar', %L::jsonb)$q$, sim.venda(:'b'),
  jsonb_build_object('os', '8' || lpad(sim._conv(:'b'), 7, '0'), 'dia', to_char(now() + interval '2 days', 'YYYY-MM-DD'), 'periodo', '13:00', 'forma', 'boleto', 'origem', 'extensao', 'sem_aviso', true)::text)), '') as r1 \gset
select sim.confere('sem plano a OS não grava, e a frase diz o que fazer', :'r1' like '%Falta o plano desta venda%'
  and (select coalesce(nio_os, '') from public.vendas where id = sim.venda(:'b')) = '', coalesce(nullif(:'r1', ''), 'aceitou'));

-- a extensão completa a VENDA com o que o humano digitou no pedido do portal
select public.venda_dados_do_portal(sim.venda(:'b'), jsonb_build_object('cpf', :'cpfb', 'nome', 'Inc X82 de Souza Lima', 'plano', 'V-REG-FIBRA',
  'forma', 'boleto', 'complemento', 'AP 12', 'referencia', 'ao lado do mercado')) as l1 \gset
select sim.confere('plano, pagamento, complemento, referência e o nome da Receita foram para a venda',
  (select v.plano_id = (select id from public.config_planos where codigo = 'V-REG-FIBRA') and v.forma_pagamento = 'boleto' and v.complemento = 'AP 12'
          and v.ponto_referencia = 'ao lado do mercado' and v.cliente_nome = 'Inc X82 de Souza Lima' from public.vendas v where v.id = sim.venda(:'b')), :'l1');
select sim.confere('o nome deixou de ser provisório (gravado também na conversa)', (select dados ->> 'nome' from public.mari_conversas where id = :'b') = 'Inc X82 de Souza Lima', null);
select sim.confere('com o plano gravado a comissão foi calculada', (select coalesce(comissao_prevista, 0) > 0 from public.vendas where id = sim.venda(:'b')),
  (select coalesce(comissao_prevista, 0)::text from public.vendas where id = sim.venda(:'b')));
select public.venda_dados_do_portal(sim.venda(:'b'), jsonb_build_object('cpf', :'cpfb', 'nome', 'Outro Nome Qualquer', 'complemento', 'CASA 2')) as l2 \gset
select sim.confere('o que já está gravado não é trocado', (select cliente_nome = 'Inc X82 de Souza Lima' and complemento = 'AP 12' from public.vendas where id = sim.venda(:'b')), :'l2');
select coalesce(sim.recusa(format($q$select public.venda_dados_do_portal(%L, '{"cpf":"52998224725","complemento":"X"}'::jsonb)$q$, sim.venda(:'b'))), '') as r2 \gset
select sim.confere('pedido de outro CPF na tela: nada é gravado na venda', :'r2' like '%não é o desta venda%', coalesce(nullif(:'r2', ''), 'aceitou'));
select coalesce(sim.recusa(format($q$select public.backoffice_momento(%L, 'os_agendar', %L::jsonb)$q$, sim.venda(:'b'),
  jsonb_build_object('os', '8' || lpad(sim._conv(:'b'), 7, '0'), 'dia', to_char(now() + interval '2 days', 'YYYY-MM-DD'), 'periodo', '13:00', 'forma', 'boleto', 'origem', 'extensao', 'sem_aviso', true)::text)), '') as r3 \gset
select sim.fila_rodar();
select sim.confere('com o plano, a OS e a agenda gravam', :'r3' = '' and (select coalesce(nio_os, '') from public.vendas where id = sim.venda(:'b')) <> '',
  coalesce(nullif(:'r3', ''), 'aceitou'));
select public.venda_dados_do_portal(sim.venda(:'b'), jsonb_build_object('cpf', :'cpfb', 'referencia', 'outra')) as l3 \gset
select sim.confere('depois da OS nada mais é completado sozinho', (:'l3'::jsonb ->> 'resumo') like '%já com OS%', :'l3');

-- (c) com a MARI atendendo, o crédito aprovado NÃO cria a venda (ela cria no handoff, com os dados completos)…
select sim.lead_pronto('Mari X82') as m \gset
select sim._servico();
select public.mari_credito_gravar(:'m', '{"resultado": "aprovado_todas", "formas_liberadas": ["BOLETO","CREDITO","DACC"]}'::jsonb);
select sim.fila_rodar();
select sim.confere('Mari atendendo: crédito aprovado não cria a venda', sim.venda(:'m') is null, null);
-- …mas quando o time assume esse lead já consultado, a venda nasce
select sim.time_no_chatwoot(:'m', '{"agente":"Atendente"}');
select sim.fila_rodar();
select sim.confere('o time assumiu o lead com crédito aprovado: a venda nasceu', sim.venda(:'m') is not null, null);

-- (d) "já é cliente" gravado pela Mari: não cria
select sim.lead_pronto('Cliente X82') as j \gset
select sim._servico();
update public.mari_conversas set elegibilidade = 'ja_cliente' where id = :'j';
select sim.time_no_chatwoot(:'j', '{"agente":"Atendente"}');
select sim.como('backoffice');
select public.lead_registrar_consulta(:'j', 'credito', 'aprovado_todas');
select sim.fila_rodar();
select sim.confere('"já é cliente": nenhuma venda nasce', sim.venda(:'j') is null, null);

-- (e) duplicidade (o CPF já tem venda ativa): não cria, o lead fica como estava e o motivo fica registrado
select sim.lead_pronto('Dup X82') as u \gset
select sim._servico();
update public.mari_conversas set dados = dados || jsonb_build_object('cpf', (select public._so_digitos(cliente_cpf_cnpj) from public.vendas where id = sim.venda(:'a'))) where id = :'u';
select sim.time_no_chatwoot(:'u', '{"agente":"Atendente"}');
select status as st_antes from public.mari_conversas where id = :'u' \gset
select sim.como('backoffice');
select public.lead_registrar_consulta(:'u', 'credito', 'aprovado_todas');
select sim.fila_rodar();
select sim.confere('duplicidade: nenhuma venda nasce e o crédito fica gravado no lead', sim.venda(:'u') is null
  and (select credito_resultado from public.mari_conversas where id = :'u') = 'aprovado_todas', null);
select sim.confere('duplicidade: a conversa fica como estava e o motivo é registrado',
  (select status from public.mari_conversas where id = :'u') = :'st_antes'
  and exists (select 1 from public.mari_erros where conversa_id = :'u' and no_n8n = 'venda_automatica' and mensagem like '%duplicidade%'),
  (select status from public.mari_conversas where id = :'u'));
