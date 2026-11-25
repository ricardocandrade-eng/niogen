-- id: X93
-- titulo: Caso L-248 (23/11): o CSV do GED360 traz DUAS linhas por protocolo (BIOMETRIA "CONCLUÍDO" e DOCUMENTO "DOC. APTO PARA VENDA") e o leitor gravava a última — a aprovação ficava escondida atrás do "Concluído" (70 min no L-248; até 4 dias no histórico) e o resultado trocava a cada leitura (o "Alerta de risco" do L-262 virou "Concluído"). Agora vale a linha mais decisiva do protocolo: risco > alerta > aprovada > espera, qualquer que seja a ordem
-- tipo: regra_nova
select sim.lead_com_venda('Leo X93') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"aprovado"}');
select sim.fila_rodar();
select regexp_replace(cliente_cpf_cnpj, '\D', '', 'g') as cpf from public.vendas where id = sim.venda(:'c') \gset
select to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') as agora \gset

-- 1ª leitura: link enviado (uma linha)
select sim._servico();
select public.ged360_registrar(jsonb_build_array(jsonb_build_object('protocolo', 'X93A' || sim._conv(:'c'), 'cpf_cnpj', :'cpf',
  'data_envio', :'agora', 'tipo_servico', 'BIOMETRIA', 'resultado', 'LINK ENVIADO')));
select sim.fila_rodar();

-- 2ª leitura: duas linhas do mesmo protocolo — o APTO vem ANTES do CONCLUÍDO (como no L-248 às 12:04)
select sim._servico();
select public.ged360_registrar(jsonb_build_array(
  jsonb_build_object('protocolo', 'X93A' || sim._conv(:'c'), 'cpf_cnpj', :'cpf', 'data_envio', :'agora', 'data_conferencia', :'agora',
                     'tipo_servico', 'DOCUMENTOSCOPIA', 'resultado', 'DOC. APTO PARA VENDA'),
  jsonb_build_object('protocolo', 'X93A' || sim._conv(:'c'), 'cpf_cnpj', :'cpf', 'data_envio', :'agora', 'data_conferencia', :'agora',
                     'tipo_servico', 'BIOMETRIA', 'resultado', 'CONCLUÍDO')));
select sim.fila_rodar();
select sim.confere('duas linhas (APTO e CONCLUÍDO): a biometria fica validada na mesma leitura',
  (select biometria_status from public.vendas where id = sim.venda(:'c')) = 'validada',
  (select biometria_status || ' · GED ' || coalesce((select resultado from public.nio_biometria where protocolo = 'X93A' || sim._conv(:'c')), '?')
     from public.vendas where id = sim.venda(:'c')));

-- 3ª leitura: as mesmas duas linhas na ordem inversa → o resultado gravado não troca
select sim._servico();
select public.ged360_registrar(jsonb_build_array(
  jsonb_build_object('protocolo', 'X93A' || sim._conv(:'c'), 'cpf_cnpj', :'cpf', 'data_envio', :'agora', 'data_conferencia', :'agora',
                     'tipo_servico', 'BIOMETRIA', 'resultado', 'CONCLUÍDO'),
  jsonb_build_object('protocolo', 'X93A' || sim._conv(:'c'), 'cpf_cnpj', :'cpf', 'data_envio', :'agora', 'data_conferencia', :'agora',
                     'tipo_servico', 'DOCUMENTOSCOPIA', 'resultado', 'DOC. APTO PARA VENDA')));
select sim.confere('ordem inversa: o GED360 continua "DOC. APTO PARA VENDA" (não volta para Concluído)',
  (select resultado from public.nio_biometria where protocolo = 'X93A' || sim._conv(:'c')) = 'DOC. APTO PARA VENDA',
  (select resultado from public.nio_biometria where protocolo = 'X93A' || sim._conv(:'c')));

-- Outra venda: ALERTA DE RISCO numa linha e CONCLUÍDO na outra (L-262) → o risco vale, em qualquer ordem
select sim.lead_com_venda('Rafa X93') as r \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'r'), 'credito', '{"resultado":"aprovado"}');
select sim.fila_rodar();
select regexp_replace(cliente_cpf_cnpj, '\D', '', 'g') as cpf2 from public.vendas where id = sim.venda(:'r') \gset
select sim._servico();
select public.ged360_registrar(jsonb_build_array(
  jsonb_build_object('protocolo', 'X93R' || sim._conv(:'r'), 'cpf_cnpj', :'cpf2', 'data_envio', :'agora', 'data_conferencia', :'agora',
                     'tipo_servico', 'DOCUMENTOSCOPIA', 'resultado', 'ALERTA DE RISCO'),
  jsonb_build_object('protocolo', 'X93R' || sim._conv(:'r'), 'cpf_cnpj', :'cpf2', 'data_envio', :'agora', 'data_conferencia', :'agora',
                     'tipo_servico', 'BIOMETRIA', 'resultado', 'CONCLUÍDO')));
select sim.fila_rodar();
select sim.confere('risco + concluído: a venda fica com risco e o GED360 mostra o alerta de risco',
  (select biometria_status from public.vendas where id = sim.venda(:'r')) = 'com_risco'
  and (select resultado from public.nio_biometria where protocolo = 'X93R' || sim._conv(:'r')) = 'ALERTA DE RISCO',
  (select biometria_status from public.vendas where id = sim.venda(:'r')) || ' · GED ' || (select resultado from public.nio_biometria where protocolo = 'X93R' || sim._conv(:'r')));
