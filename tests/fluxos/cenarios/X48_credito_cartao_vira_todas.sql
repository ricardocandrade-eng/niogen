-- id: X48
-- titulo: Caso L-203 (19/11, Chatwoot 185): crédito gravado "só cartão" e o portal depois diz "todas as formas" → o BKO troca para aprovado (e de volta) antes da OS; negado/pendente seguem recusados (outro CPF = Trocar o titular)
-- tipo: atual
select sim.lead_com_venda('Leo X48') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"so_cartao"}');
select sim.fila_rodar();
select coalesce((select situacao from public.v_lead_situacao where venda_id = sim.venda(:'c')), '') as s1 \gset
select sim.confere('com o crédito gravado, o lead passou do degrau do crédito', :'s1' in ('qualificado_biometria', 'qualificado_os', 'qualificado_credito'), :'s1');

select coalesce(sim.recusa(format($q$select public.backoffice_momento(%L, 'credito', '{"resultado":"aprovado"}')$q$, sim.venda(:'c'))), '') as r1 \gset
select sim.confere('só cartão → todas as formas é aceito', :'r1' = '', :'r1');
select sim.confere('a venda ficou aprovada em todas', (select credito_resultado from public.vendas where id = sim.venda(:'c')) = 'aprovado',
  (select credito_resultado from public.vendas where id = sim.venda(:'c')));

select coalesce(sim.recusa(format($q$select public.backoffice_momento(%L, 'credito', '{"resultado":"so_cartao"}')$q$, sim.venda(:'c'))), '') as r2 \gset
select sim.confere('todas → só cartão também (o portal pode voltar atrás)', :'r2' = '', :'r2');

-- na situação seguinte ao crédito (biometria), o mapa aceita trocar a forma mas não negado nem pendente
select sim.confere('qualificado_biometria: aprovado aceito', (select aceito from public.porta_prever('qualificado_biometria', 'momento:credito:aprovado')), null);
select sim.confere('qualificado_biometria: só cartão aceito', (select aceito from public.porta_prever('qualificado_biometria', 'momento:credito:so_cartao')), null);
select sim.confere('qualificado_os: aprovado aceito', (select aceito from public.porta_prever('qualificado_os', 'momento:credito:aprovado')), null);
select sim.confere('qualificado_biometria: negado continua recusado (Trocar o titular)', (select aceito from public.porta_prever('qualificado_biometria', 'momento:credito:negado')) is false, null);
select sim.confere('qualificado_os: pendente continua recusado', (select aceito from public.porta_prever('qualificado_os', 'momento:credito:pendente')) is false, null);
select sim.confere('com a OS (instalação), trocar o crédito segue recusado', (select aceito from public.porta_prever('instalacao_agendar', 'momento:credito:aprovado')) is false, null);
