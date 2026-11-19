-- id: X49
-- titulo: Caso L-203 (19/11, Chatwoot 185): o link da biometria sai do portal na etapa do crédito (sem Pedido gravado) → o GED360 lê "LINK ENVIADO" e o NIOGEN avisa o cliente UMA vez (nota + mensagem); se o aviso já saiu pelo Pedido, não repete; Não contatar barra
-- tipo: atual
select sim.lead_com_venda('Ivo X49') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"so_cartao"}');
select sim.fila_rodar();
select regexp_replace(cliente_cpf_cnpj, '\D', '', 'g') as cpf from public.vendas where id = sim.venda(:'c') \gset
select to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') as agora \gset

-- 1ª leitura do GED360: LINK ENVIADO
select sim._servico();
select public.ged360_registrar(jsonb_build_array(jsonb_build_object('protocolo', 'X49A' || sim._conv(:'c'), 'cpf_cnpj', :'cpf',
  'data_envio', :'agora', 'tipo_servico', 'BIOMETRIA', 'resultado', 'LINK ENVIADO')));
select sim.fila_rodar();
select sim.confere('o GED360 deixou a biometria pendente', (select biometria_status from public.vendas where id = sim.venda(:'c')) = 'pendente',
  (select biometria_status from public.vendas where id = sim.venda(:'c')));
select count(*) as n1 from public.chatwoot_acoes where venda_id = sim.venda(:'c') and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_ged_biometria'
   and status in ('pendente', 'executando', 'feita') \gset
select sim.confere('o cliente recebeu o aviso do link da biometria (1 mensagem)', :n1 = 1, :'n1');
select sim.confere('a nota interna diz que o GED360 viu o link',
  exists (select 1 from public.chatwoot_acoes where venda_id = sim.venda(:'c') and tipo = 'nota' and payload ->> 'content' like '%GED360%link%'), null);

-- 2ª leitura igual (o robô roda a cada 15 min): não repete
select sim._servico();
select public.ged360_registrar(jsonb_build_array(jsonb_build_object('protocolo', 'X49A' || sim._conv(:'c'), 'cpf_cnpj', :'cpf',
  'data_envio', :'agora', 'tipo_servico', 'BIOMETRIA', 'resultado', 'LINK ENVIADO')));
select sim.fila_rodar();
select count(*) as n2 from public.chatwoot_acoes where venda_id = sim.venda(:'c') and tipo = 'mensagem' and payload ->> 'texto_chave' like 'bo_%biometria'
   and status in ('pendente', 'executando', 'feita') \gset
select sim.confere('a leitura seguinte não repete o aviso', :n2 = 1, :'n2');

-- aviso que já saiu pelo Pedido: o GED360 não manda outro
select sim.lead_com_venda('Ana X49') as p \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'p'), 'credito', '{"resultado":"aprovado"}');
select public.backoffice_momento(sim.venda(:'p'), 'pedido', jsonb_build_object('pedido', 'P' || sim._conv(:'p')));
select sim.fila_rodar();
select regexp_replace(cliente_cpf_cnpj, '\D', '', 'g') as cpf2 from public.vendas where id = sim.venda(:'p') \gset
select sim._servico();
select public.ged360_registrar(jsonb_build_array(jsonb_build_object('protocolo', 'X49B' || sim._conv(:'p'), 'cpf_cnpj', :'cpf2',
  'data_envio', :'agora', 'tipo_servico', 'BIOMETRIA', 'resultado', 'LINK ENVIADO')));
select sim.fila_rodar();
select count(*) as n3 from public.chatwoot_acoes where venda_id = sim.venda(:'p') and tipo = 'mensagem' and payload ->> 'texto_chave' like 'bo_%biometria'
   and status in ('pendente', 'executando', 'feita') \gset
select sim.confere('com o aviso já dado pelo Pedido, o GED360 não manda outro', :n3 = 1, :'n3');
