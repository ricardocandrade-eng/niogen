-- id: X54
-- titulo: 0327 (Ricardo, 19/11: "a notícia, seja qual for, deve ser automática"): o resultado do crédito avisa o cliente na hora, com a Mari ou com o time — aprovado com a forma escolhida, forma não liberada, só cartão (cartão ou outro titular), negado (outro titular), pendente; uma vez só; Não contatar barra; marca o que a Mari já não precisa repetir
-- tipo: atual

-- A) Mari atendendo, crédito automático APROVADO (todas as formas): avisa com a forma escolhida (boleto)
select sim.lead_pronto('Ana X54') as a \gset
select sim._servico();
select public.mari_credito_gravar(:'a', '{"resultado": "aprovado_todas", "formas_liberadas": ["BOLETO","CREDITO","DACC"]}'::jsonb);
select sim.fila_rodar();
select count(*) as na from public.chatwoot_acoes where conversa_id = :'a' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_aprovado'
   and status in ('pendente', 'executando', 'feita') \gset
select sim.confere('aprovado: o cliente recebeu o aviso (1 mensagem)', :na = 1, :'na');
select sim.confere('aprovado: o aviso diz a forma escolhida (boleto)',
  exists (select 1 from public.chatwoot_acoes where conversa_id = :'a' and payload ->> 'texto_chave' = 'bo_credito_aprovado' and payload ->> 'content' like '%boleto%'), null);
select sim.confere('aprovado: marcado como avisado', ((select dados from public.mari_conversas where id = :'a') ->> 'credito_aprovado_avisado') = 'true', null);
select sim._servico();
select public.mari_credito_gravar(:'a', '{"resultado": "aprovado_todas", "formas_liberadas": ["BOLETO","CREDITO","DACC"]}'::jsonb);
select sim.fila_rodar();
select count(*) as na2 from public.chatwoot_acoes where conversa_id = :'a' and tipo = 'mensagem' and payload ->> 'texto_chave' like 'bo_credito_%'
   and status in ('pendente', 'executando', 'feita') \gset
select sim.confere('o mesmo resultado de novo não repete o aviso', :na2 = 1, :'na2');

-- B) Mari atendendo, SÓ CARTÃO e o cliente escolheu boleto: cartão ou outra pessoa da casa como titular
select sim.lead_pronto('Bia X54') as b \gset
select sim._servico();
select public.mari_credito_gravar(:'b', '{"resultado": "aprovado_cartao", "formas_liberadas": ["CREDITO"]}'::jsonb);
select sim.fila_rodar();
select sim.confere('só cartão: saiu o aviso do cartão com o outro titular',
  exists (select 1 from public.chatwoot_acoes where conversa_id = :'b' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_cartao'
           and status in ('pendente', 'executando', 'feita') and payload ->> 'content' like '%titular%'), null);
select sim.confere('só cartão: a Mari não repete (credito_cartao_avisado)', ((select dados from public.mari_conversas where id = :'b') ->> 'credito_cartao_avisado') = 'true', null);

-- C) Mari atendendo, APROVADO PARCIAL sem a forma escolhida (boleto): pede uma das liberadas
select sim.lead_pronto('Caio X54') as f \gset
select sim._servico();
select public.mari_credito_gravar(:'f', '{"resultado": "aprovado_parcial", "formas_liberadas": ["CREDITO","DACC"]}'::jsonb);
select sim.fila_rodar();
select sim.confere('forma não liberada: o aviso diz quais formas valem',
  exists (select 1 from public.chatwoot_acoes where conversa_id = :'f' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_forma'
           and payload ->> 'content' like '%cartão de crédito%' and payload ->> 'content' like '%débito em conta%'), null);

-- D) Mari atendendo, NEGADO (1ª consulta): outro titular; a Mari não repete; a conversa segue com a Mari até o cliente responder
select sim.lead_pronto('Davi X54') as d \gset
select sim._servico();
select public.mari_credito_gravar(:'d', '{"resultado": "negado"}'::jsonb);
select sim.fila_rodar();
select sim.confere('negado: saiu o aviso oferecendo outro titular',
  exists (select 1 from public.chatwoot_acoes where conversa_id = :'d' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_negado'
           and status in ('pendente', 'executando', 'feita') and payload ->> 'content' like '%titular%'), null);
select sim.confere('negado: marcado para a Mari passar ao time na próxima fala',
  ((select dados from public.mari_conversas where id = :'d') ->> 'credito_negado_avisado') = 'true', null);

-- E) PENDENTE: avisa que a Nio responde em até 24 h
select sim.lead_pronto('Eva X54') as e \gset
select sim._servico();
select public.mari_credito_gravar(:'e', '{"resultado": "pendente"}'::jsonb);
select sim.fila_rodar();
select sim.confere('pendente: o cliente sabe que a Nio responde em até 24 h',
  exists (select 1 from public.chatwoot_acoes where conversa_id = :'e' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_pendente'), null);

-- F) Venda com o TIME (backoffice assumiu), crédito pelo botão "só cartão": o aviso sai mesmo assim, em nome da pessoa
select sim.lead_com_venda('Fabi X54') as t \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'t'), 'assumir');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'t'), 'credito', '{"resultado":"so_cartao"}');
select sim.fila_rodar();
select sim.confere('com o time na conversa, o aviso do só cartão sai (aviso da venda), em nome da pessoa',
  exists (select 1 from public.chatwoot_acoes where conversa_id = :'t' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_cartao'
           and status in ('pendente', 'executando', 'feita') and payload ->> 'como' = 'humano'), null);

-- G) Venda com o time, NEGADO pelo botão: um aviso só (o 'pedido de outro CPF' antigo não duplica)
select sim.lead_com_venda('Gil X54') as g \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'g'), 'assumir');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'g'), 'credito', '{"resultado":"negado"}');
select sim.fila_rodar();
select count(*) as ng from public.chatwoot_acoes where conversa_id = :'g' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_negado'
   and status in ('pendente', 'executando', 'feita') \gset
select sim.confere('negado pelo botão com o time: 1 aviso ao cliente', :ng = 1, :'ng');

-- H) Não contatar barra o aviso (venda parada pelo botão "Não contatar")
select sim.lead_com_venda('Hugo X54') as h \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'h'), 'parar');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'h'), 'credito', '{"resultado":"aprovado"}');
select sim.fila_rodar();
select sim.confere('Não contatar: nenhum aviso do crédito sai ao cliente',
  not exists (select 1 from public.chatwoot_acoes where conversa_id = :'h' and tipo = 'mensagem' and payload ->> 'texto_chave' like 'bo_credito_%'
               and status in ('pendente', 'executando', 'feita')), null);

-- I) a Mari consulta e dá SÓ CARTÃO (aviso sai); depois o BKO grava o mesmo "só cartão" na ficha/extensão → não sai de novo
select sim.lead_com_venda('Ivo X54') as i \gset
select sim._servico();
select public.mari_credito_gravar(:'i', '{"resultado": "aprovado_cartao", "formas_liberadas": ["CREDITO"]}'::jsonb);
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'i'), 'credito', '{"resultado":"so_cartao"}');
select sim.fila_rodar();
select count(*) as ni from public.chatwoot_acoes where conversa_id = :'i' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_cartao'
   and status in ('pendente', 'executando', 'feita') \gset
select sim.confere('Mari e botão com o mesmo só cartão: 1 aviso ao cliente', :ni = 1, :'ni');

-- J) a Mari consulta e dá SÓ CARTÃO; a extensão grava "aprovado" na venda (sem ler o popup) → não sai "aprovado no boleto"
select sim.lead_com_venda('Jo X54') as j \gset
select sim._servico();
select public.mari_credito_gravar(:'j', '{"resultado": "aprovado_cartao", "formas_liberadas": ["CREDITO"]}'::jsonb);
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'j'), 'credito', '{"resultado":"aprovado"}');
select sim.fila_rodar();
select sim.confere('extensão grava aprovado depois do só cartão da Mari: nenhum "aprovado" ao cliente',
  not exists (select 1 from public.chatwoot_acoes where conversa_id = :'j' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_aprovado'
               and status in ('pendente', 'executando', 'feita')), null);
-- K) negado pela Mari; o BKO consulta o parente e grava "aprovado" → o aviso de aprovado sai
select sim.lead_com_venda('Ka X54') as k \gset
select sim._servico();
select public.mari_credito_gravar(:'k', '{"resultado": "negado"}'::jsonb);
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'k'), 'credito', '{"resultado":"aprovado"}');
select sim.fila_rodar();
select sim.confere('negado e depois aprovado (parente): sai o aviso de aprovado',
  exists (select 1 from public.chatwoot_acoes where conversa_id = :'k' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_aprovado'
           and status in ('pendente', 'executando', 'feita')), null);
