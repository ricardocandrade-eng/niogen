-- id: X55
-- titulo: 0330 (etapa A, Ricardo 20/11: "se é o Portal, seja quem for gravar, que grave, sem o humano se envolver"): o crédito lido pela Mari vai para a venda sozinho (e a venda nasce com ele), o botão da ficha/extensão grava também a conversa, o "aprovado" do botão não apaga o "só cartão" do operador, o aviso ao cliente sai uma vez, o Corrigir exige motivo, e a viabilidade nova do operador chega à venda
-- tipo: atual

-- A) a Mari consultou ANTES do handoff (aprovado, todas as formas): a venda nasce com o crédito, origem operador, próximo passo biometria
select sim.lead_pronto('Ana X55') as a \gset
select sim._servico();
select public.mari_credito_gravar(:'a', '{"resultado": "aprovado_todas", "formas_liberadas": ["BOLETO","CREDITO","DACC"]}'::jsonb);
select sim.mari_handoff(:'a', 'dados_completos', '{}'::jsonb);
select sim.fila_rodar();
select sim.confere('a venda nasceu com o crédito aprovado (sem ninguém gravar na ficha)',
  (select credito_resultado from public.vendas where id = sim.venda(:'a')) = 'aprovado', (select coalesce(credito_resultado, 'null') from public.vendas where id = sim.venda(:'a')));
select sim.confere('origem do crédito na venda = operador', (select credito_origem from public.vendas where id = sim.venda(:'a')) = 'operador', null);
select sim.confere('evento credito_aprovado_portal (próximo passo: biometria)',
  exists (select 1 from public.eventos_venda where venda_id = sim.venda(:'a') and tipo = 'credito_aprovado_portal'), null);
select count(*) as na from public.chatwoot_acoes where conversa_id = :'a' and tipo = 'mensagem' and payload ->> 'texto_chave' like 'bo_credito_%'
   and status in ('pendente', 'executando', 'feita') \gset
select sim.confere('o cliente recebeu UM aviso do crédito', :na = 1, :'na');

-- B) com a venda já aberta, a Mari lê SÓ CARTÃO: a venda vira so_cartao sozinha, um aviso só
select sim.lead_com_venda('Bia X55') as b \gset
select sim._servico();
select public.mari_credito_gravar(:'b', '{"resultado": "aprovado_cartao", "formas_liberadas": ["CREDITO"]}'::jsonb);
select sim.fila_rodar();
select sim.confere('só cartão da Mari chegou à venda', (select credito_resultado from public.vendas where id = sim.venda(:'b')) = 'so_cartao', null);
select count(*) as nb from public.chatwoot_acoes where conversa_id = :'b' and tipo = 'mensagem' and payload ->> 'texto_chave' like 'bo_credito_%'
   and status in ('pendente', 'executando', 'feita') \gset
select sim.confere('só cartão: um aviso só (o espelho não repete)', :nb = 1, :'nb');

-- C) o botão da ficha grava NEGADO: a conversa fica negado também (a Mari lê o mesmo)
select sim.lead_com_venda('Caio X55') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"negado"}');
select sim.fila_rodar();
select sim.confere('negado do botão chegou à conversa', (select credito_resultado from public.mari_conversas where id = :'c') = 'negado', null);
select count(*) as nc from public.chatwoot_acoes where conversa_id = :'c' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_negado'
   and status in ('pendente', 'executando', 'feita') \gset
select sim.confere('negado do botão: um aviso ao cliente', :nc = 1, :'nc');

-- D) a Mari leu SÓ CARTÃO; a extensão grava "aprovado": a conversa segue só cartão e a conferência mostra a divergência
select sim.lead_com_venda('Davi X55') as d \gset
select sim._servico();
select public.mari_credito_gravar(:'d', '{"resultado": "aprovado_cartao", "formas_liberadas": ["CREDITO"]}'::jsonb);
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'d'), 'credito', '{"resultado":"aprovado"}');
select sim.fila_rodar();
select sim.confere('o "aprovado" do botão não apagou o só cartão do operador',
  (select credito_resultado from public.mari_conversas where id = :'d') = 'aprovado_cartao', null);
select sim._servico();
select coalesce((select (x ->> 'n')::int from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'credito_um_lugar'), -1) as div \gset
select sim.confere('a conferência mostra a divergência', :div >= 1, :'div');

-- E) Corrigir: sem motivo é recusado; com motivo grava, com evento
select sim.como('backoffice');
select sim.recusa(format('select public.credito_corrigir(%L, %L, %L)', sim.venda(:'d'), 'so_cartao', '')) as r1 \gset
select sim.confere('Corrigir sem motivo é recusado', :'r1' like '%motivo%', :'r1');
select public.credito_corrigir(sim.venda(:'d'), 'so_cartao', 'portal_outro', 'portal mostrou só cartão');
select sim.fila_rodar();
select sim.confere('Corrigir com motivo: venda so_cartao e evento credito_corrigido',
  (select credito_resultado from public.vendas where id = sim.venda(:'d')) = 'so_cartao'
  and exists (select 1 from public.eventos_venda where venda_id = sim.venda(:'d') and tipo = 'credito_corrigido' and detalhe ->> 'motivo' = 'portal_outro'), null);

-- F) viabilidade: leitura nova do operador na conversa chega à venda (origem mari)
select sim.lead_com_venda('Eva X55') as e \gset
select sim._servico();
update public.mari_conversas set nio_viab_resultado = 'viavel', nio_viab_velocidade = '600 Mega', nio_viab_em = now() + interval '1 minute' where id = :'e';
select sim.confere('viabilidade nova do operador chegou à venda',
  (select nio_viab_origem = 'mari' and nio_viab_velocidade = '600 Mega' from public.vendas where id = sim.venda(:'e')), null);
