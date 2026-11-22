-- id: X79
-- titulo: Caso L-219 (22/11, Chatwoot 199): lead conduzido pelo time, sem venda, com o crédito aprovado gravado na ficha e o pedido feito à mão no portal — o GED360 lê o link da biometria e o NIOGEN avisa o cliente UMA vez (antes só avisava venda; o time mandou à mão); aprovada → nota para o time virar venda, sem mensagem ao cliente; e a porta deixa esse lead virar venda (antes: "Este lead já é venda")
-- tipo: atual
select sim.lead_pronto('Cintia X79') as c \gset
-- 0356: com o TIME dono da conversa, o crédito aprovado já cria a venda (cenário X82). Aqui fica o caso que sobra: lead sem
-- venda e sem dono (a Mari atendendo), com o crédito aprovado gravado pelo backoffice e o pedido feito à mão no portal.
select sim.como('backoffice');
select public.lead_registrar_consulta(:'c', 'credito', 'aprovado_todas');
select sim.fila_rodar();
select sim.confere('o lead segue sem venda, com o crédito aprovado', sim.venda(:'c') is null
  and (select credito_resultado from public.mari_conversas where id = :'c') = 'aprovado_todas', null);
select public._so_digitos(dados ->> 'cpf') as cpf from public.mari_conversas where id = :'c' \gset
select to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') as agora \gset

-- o time faz o pedido no portal; o GED360 lê LINK ENVIADO para o CPF do lead
select sim._servico();
select public.ged360_registrar(jsonb_build_array(jsonb_build_object('protocolo', 'X79A' || sim._conv(:'c'), 'cpf_cnpj', :'cpf',
  'data_envio', :'agora', 'tipo_servico', 'BIOMETRIA', 'resultado', 'LINK ENVIADO')));
select sim.fila_rodar();
select count(*) as n1 from public.chatwoot_acoes where conversa_id = :'c' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_ged_biometria'
   and status in ('pendente', 'executando', 'feita') \gset
select sim.confere('o cliente do lead sem venda recebeu o aviso do link da biometria (1 mensagem)', :n1 = 1, :'n1');
select sim.confere('a nota interna diz que o GED360 viu o link e que o lead ainda não é venda',
  exists (select 1 from public.chatwoot_acoes where conversa_id = :'c' and tipo = 'nota' and payload ->> 'content' like '%GED360%link%não é venda%'), null);

-- a leitura seguinte (15 min depois), igual: não repete
select sim._servico();
select public.ged360_registrar(jsonb_build_array(jsonb_build_object('protocolo', 'X79A' || sim._conv(:'c'), 'cpf_cnpj', :'cpf',
  'data_envio', :'agora', 'tipo_servico', 'BIOMETRIA', 'resultado', 'LINK ENVIADO')));
select sim.fila_rodar();
select count(*) as n2 from public.chatwoot_acoes where conversa_id = :'c' and tipo = 'mensagem' and payload ->> 'texto_chave' like 'bo_%biometria'
   and status in ('pendente', 'executando', 'feita') \gset
select sim.confere('a leitura seguinte não repete o aviso', :n2 = 1, :'n2');

-- o cliente faz a biometria: o GED360 lê DOC. APTO PARA VENDA → nota para o time virar venda; nada novo ao cliente
select sim._servico();
select public.ged360_registrar(jsonb_build_array(jsonb_build_object('protocolo', 'X79A' || sim._conv(:'c'), 'cpf_cnpj', :'cpf',
  'data_envio', :'agora', 'tipo_servico', 'BIOMETRIA', 'resultado', 'DOC. APTO PARA VENDA')));
select sim.fila_rodar();
select sim.confere('aprovada: nota para o time virar venda e gravar a OS',
  exists (select 1 from public.chatwoot_acoes where conversa_id = :'c' and tipo = 'nota' and payload ->> 'content' like '%Biometria aprovada%Virar venda%'), null);
select sim.confere('aprovada: a leitura sem venda ganha o alerta "agora"',
  (select alerta_nivel from public.nio_biometria where protocolo = 'X79A' || sim._conv(:'c')) = 'agora',
  (select coalesce(alerta, '—') from public.nio_biometria where protocolo = 'X79A' || sim._conv(:'c')));
select count(*) as n3 from public.chatwoot_acoes where conversa_id = :'c' and tipo = 'mensagem' and payload ->> 'texto_chave' like 'bo_%biometria'
   and status in ('pendente', 'executando', 'feita') \gset
select sim.confere('aprovada: nenhuma mensagem nova ao cliente', :n3 = 1, :'n3');

-- a porta deixa o lead sem venda, em qualificado_credito, virar venda (antes: "Este lead já é venda")
select sim.como('backoffice');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '?') as s1 \gset
select sim.confere('o lead sem venda com crédito aprovado está em qualificado_credito', :'s1' = 'qualificado_credito', :'s1');
select coalesce(sim.recusa(format($q$select public.lead_virar_venda(%L)$q$, :'c')), '') as r1 \gset
select sim.confere('Virar venda aceito para o lead sem venda', :'r1' = '' and sim.venda(:'c') is not null, coalesce(nullif(:'r1', ''), 'aceitou'));
select sim.fila_rodar();
select sim.confere('ao virar venda, a biometria aprovada que o GED360 já tinha lido vale na hora (sem esperar o robô)',
  (select biometria_status from public.vendas where id = sim.venda(:'c')) = 'validada',
  (select biometria_status from public.vendas where id = sim.venda(:'c')));
select coalesce(sim.recusa(format($q$select public.backoffice_momento(%L, 'os_agendar', %L::jsonb)$q$, sim.venda(:'c'),
  jsonb_build_object('os', '9' || lpad(sim._conv(:'c'), 7, '0'), 'dia', to_char(now() + interval '2 days', 'YYYY-MM-DD'), 'periodo', '13:00', 'forma', 'boleto', 'origem', 'extensao', 'sem_aviso', true)::text)), '') as ro \gset
select sim.fila_rodar();
select sim.confere('e a OS com a agenda grava em seguida, à mão', :'ro' = '' and (select coalesce(nio_os, '') from public.vendas where id = sim.venda(:'c')) <> '',
  coalesce(nullif(:'ro', ''), 'aceitou'));

-- nova leitura do GED360 depois de virar venda: nada muda e NÃO sai outro aviso do link
select sim._servico();
select public.ged360_registrar(jsonb_build_array(jsonb_build_object('protocolo', 'X79A' || sim._conv(:'c'), 'cpf_cnpj', :'cpf',
  'data_envio', :'agora', 'tipo_servico', 'BIOMETRIA', 'resultado', 'DOC. APTO PARA VENDA')));
select sim.fila_rodar();
select sim.confere('depois de virar venda, a biometria aprovada vale na venda',
  (select biometria_status from public.vendas where id = sim.venda(:'c')) = 'validada',
  (select biometria_status from public.vendas where id = sim.venda(:'c')));
select count(*) as n4 from public.chatwoot_acoes where conversa_id = :'c' and tipo = 'mensagem' and payload ->> 'texto_chave' like 'bo_%biometria'
   and status in ('pendente', 'executando', 'feita') \gset
select sim.confere('depois de virar venda, nenhum aviso repetido da biometria', :n4 = 1, :'n4');

-- lead em Saída: o GED360 não avisa
select sim.lead_pronto('Saiu X79') as s \gset
select sim.como('backoffice');
select public.lead_registrar_consulta(:'s', 'credito', 'aprovado_todas');
select public.lead_sair(:'s', null, 'recusou', 'preco');
select sim.fila_rodar();
select public._so_digitos(dados ->> 'cpf') as cpf2 from public.mari_conversas where id = :'s' \gset
select sim._servico();
select public.ged360_registrar(jsonb_build_array(jsonb_build_object('protocolo', 'X79B' || sim._conv(:'s'), 'cpf_cnpj', :'cpf2',
  'data_envio', :'agora', 'tipo_servico', 'BIOMETRIA', 'resultado', 'LINK ENVIADO')));
select sim.fila_rodar();
select count(*) as n5 from public.chatwoot_acoes where conversa_id = :'s' and tipo = 'mensagem' and payload ->> 'texto_chave' like 'bo_%biometria' \gset
select sim.confere('lead em Saída não recebe o aviso da biometria', :n5 = 0, :'n5');

-- lead conduzido só pelo time: a Mari nunca perguntou elegibilidade, plano nem nome (como o L-219)
select sim.lead_pronto('Time X79') as t \gset
select sim._servico();
update public.mari_conversas set elegibilidade = null, plano_escolhido = null, dados = dados - 'nome' where id = :'t';
select sim.como('backoffice');
select public.lead_registrar_consulta(:'t', 'credito', 'aprovado_todas');
select sim.fila_rodar();
select coalesce(sim.recusa(format($q$select public.lead_virar_venda(%L)$q$, :'t')), '') as r2 \gset
select sim.confere('Virar venda diz de uma vez o que falta gravar (plano e nome)', :'r2' like '%falta gravar na ficha%plano%nome do titular%',
  coalesce(nullif(:'r2', ''), 'aceitou'));
select sim.confere('recusado: nenhuma venda nasceu', sim.venda(:'t') is null, null);
select public.lead_corrigir(:'t', '{"nome":"Time X79 Silva","plano":"V-REG-SUP"}'::jsonb);
select coalesce(sim.recusa(format($q$select public.lead_virar_venda(%L)$q$, :'t')), '') as r3 \gset
select sim.fila_rodar();
select sim.confere('com plano e nome gravados, o lead do time vira venda (elegibilidade vazia + crédito aprovado no portal)',
  :'r3' = '' and sim.venda(:'t') is not null, coalesce(nullif(:'r3', ''), 'aceitou'));
select sim.confere('a elegibilidade ficou "ok" com a marca de quem virou a venda',
  (select elegibilidade from public.mari_conversas where id = :'t') = 'ok'
  and exists (select 1 from public.mari_turnos where conversa_id = :'t' and papel = 'sistema' and texto like '[elegibilidade confirmada pelo crédito aprovado%'), null);

-- "já é cliente" gravado pela Mari continua barrando o Virar venda
select sim.lead_pronto('Cliente X79') as j \gset
select sim._servico();
update public.mari_conversas set elegibilidade = 'ja_cliente' where id = :'j';
select sim.como('backoffice');
select public.lead_registrar_consulta(:'j', 'credito', 'aprovado_todas');
select coalesce(sim.recusa(format($q$select public.lead_virar_venda(%L)$q$, :'j')), '') as r4 \gset
select sim.confere('elegibilidade "ja_cliente" continua barrando', :'r4' <> '' and sim.venda(:'j') is null, coalesce(nullif(:'r4', ''), 'aceitou'));

-- extensão 0.10.0: o que o humano digitou no pedido do portal completa a ficha do lead (só o que está vazio)
select sim.lead_pronto('Portal X79') as p \gset
select sim._servico();
update public.mari_conversas set plano_escolhido = null, forma_pagamento = null, complemento = null, dados = dados - 'nome' - 'referencia' where id = :'p';
select nio_viab_resultado as viab_antes from public.mari_conversas where id = :'p' \gset
select public._so_digitos(dados ->> 'cpf') as cpf3, dados ->> 'email' as email3 from public.mari_conversas where id = :'p' \gset
select sim.como('backoffice');
select public.lead_dados_do_portal(:'p', jsonb_build_object('cpf', :'cpf3', 'nome', 'Portal X79 da Silva', 'complemento', 'AP 302',
  'referencia', 'perto da padaria', 'plano', 'V-REG-FIBRA', 'forma', 'boleto', 'email', 'outro@exemplo.test')) as l1 \gset
select sim.confere('nome, complemento, referência, plano e pagamento lidos do portal foram para a ficha do lead',
  (select dados ->> 'nome' = 'Portal X79 da Silva' and complemento = 'AP 302' and dados ->> 'referencia' = 'perto da padaria'
          and plano_escolhido = 'V-REG-FIBRA' and forma_pagamento = 'boleto' from public.mari_conversas where id = :'p'), :'l1');
select sim.confere('o que já estava gravado não é trocado (e-mail)', (select dados ->> 'email' from public.mari_conversas where id = :'p') = :'email3', null);
select sim.confere('a viabilidade gravada continua valendo (o pedido no portal é deste endereço)',
  (select nio_viab_resultado from public.mari_conversas where id = :'p') is not distinct from :'viab_antes', null);
select sim.confere('fica o registro de quem e do quê',
  exists (select 1 from public.mari_turnos where conversa_id = :'p' and papel = 'sistema' and texto like '[dados lidos do pedido no portal%complemento%'), null);
select coalesce(sim.recusa(format($q$select public.lead_dados_do_portal(%L, '{"cpf":"52998224725","nome":"Outra Pessoa Qualquer"}'::jsonb)$q$, :'p')), '') as r5 \gset
select sim.confere('pedido de outro CPF na tela: nada é gravado', :'r5' like '%não é o deste lead%'
  and (select dados ->> 'nome' from public.mari_conversas where id = :'p') = 'Portal X79 da Silva', coalesce(nullif(:'r5', ''), 'aceitou'));
select sim.como('vendedor');
select coalesce(sim.recusa(format($q$select public.lead_dados_do_portal(%L, '{"nome":"Fulano de Tal"}'::jsonb)$q$, :'p')), '') as r6 \gset
select sim.confere('só admin ou backoffice', :'r6' like '%admin ou backoffice%', coalesce(nullif(:'r6', ''), 'aceitou'));
