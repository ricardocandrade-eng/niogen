-- id: X85
-- titulo: Caso L-219 (22/11): a venda já tinha OS e instalação agendada e continuava na Live como "Biometria APROVADA · seguir no portal: forma de pagamento, agenda e OS → Gravar venda" — o alerta só saía com o "visto" na ficha; agora gravar a OS (o que o alerta pede) fecha o alerta sozinho, e alerta de risco continua aberto
-- tipo: atual
select sim.lead_pronto('Alerta X85') as a \gset
select sim.time_no_chatwoot(:'a', '{"agente":"Atendente"}');
select sim.time_fala_no_chatwoot(:'a', 'Oi, sou do time. Vou rodar seu crédito.');
select sim.como('backoffice');
select public.lead_registrar_consulta(:'a', 'credito', 'aprovado_todas');
select sim.fila_rodar();
select sim.confere('a venda nasceu (crédito aprovado com o time)', sim.venda(:'a') is not null, null);

-- a biometria aprova antes da OS: o alerta "seguir no portal" aparece
select public._so_digitos(cliente_cpf_cnpj) as cpfa from public.vendas where id = sim.venda(:'a') \gset
select to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') as agora \gset
select sim._servico();
select public.ged360_registrar(jsonb_build_array(jsonb_build_object('protocolo', 'X85A' || sim._conv(:'a'), 'cpf_cnpj', :'cpfa',
  'data_envio', :'agora', 'tipo_servico', 'BIOMETRIA', 'resultado', 'DOC. APTO PARA VENDA')));
select sim.fila_rodar();
select sim.confere('biometria aprovada sem OS: o alerta "seguir no portal" está aberto',
  exists (select 1 from public.nio_biometria where venda_id = sim.venda(:'a') and alerta like 'Biometria APROVADA%seguir no portal%' and alerta_visto_em is null),
  (select coalesce(alerta, '—') from public.nio_biometria where venda_id = sim.venda(:'a') limit 1));

-- o time grava a OS e a agenda: o alerta fecha sozinho
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'a'), 'os_agendar',
  jsonb_build_object('os', '8' || lpad(sim._conv(:'a'), 7, '0'), 'dia', to_char(now() + interval '2 days', 'YYYY-MM-DD'), 'periodo', '13:00', 'forma', 'boleto', 'origem', 'extensao', 'sem_aviso', true));
select sim.fila_rodar();
select sim.confere('a OS foi gravada', (select coalesce(nio_os, '') from public.vendas where id = sim.venda(:'a')) <> '', null);
select sim.confere('com a OS gravada o alerta "Biometria APROVADA" saiu sozinho (visto pelo sistema)',
  not exists (select 1 from public.nio_biometria where venda_id = sim.venda(:'a') and alerta like 'Biometria APROVADA%' and alerta_visto_em is null),
  (select coalesce(alerta, '—') || ' · visto: ' || coalesce(alerta_visto_em::text, 'não') from public.nio_biometria where venda_id = sim.venda(:'a') limit 1));

-- alerta que pede uma pessoa (risco) não é fechado pela OS
select sim.lead_pronto('Risco X85') as r \gset
select sim.time_no_chatwoot(:'r', '{"agente":"Atendente"}');
select sim.como('backoffice');
select public.lead_registrar_consulta(:'r', 'credito', 'aprovado_todas');
select sim.fila_rodar();
select public._so_digitos(cliente_cpf_cnpj) as cpfr from public.vendas where id = sim.venda(:'r') \gset
select sim._servico();
select public.ged360_registrar(jsonb_build_array(jsonb_build_object('protocolo', 'X85R' || sim._conv(:'r'), 'cpf_cnpj', :'cpfr',
  'data_envio', :'agora', 'tipo_servico', 'BIOMETRIA', 'resultado', 'COM RISCO')));
select sim.fila_rodar();
-- (a ficha recusa OS com biometria em risco — 0256; aqui a OS entra direto no banco, como viria do OSAB)
update public.vendas set nio_os = '8' || lpad(sim._conv(:'r'), 7, '0') where id = sim.venda(:'r');
select sim.confere('alerta de risco continua aberto depois da OS',
  exists (select 1 from public.nio_biometria where venda_id = sim.venda(:'r') and alerta like '%RISCO%' and alerta_visto_em is null),
  (select coalesce(alerta, '—') || ' · visto: ' || coalesce(alerta_visto_em::text, 'não') from public.nio_biometria where venda_id = sim.venda(:'r') limit 1));
