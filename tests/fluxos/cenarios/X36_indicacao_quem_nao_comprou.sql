-- id: X36
-- titulo: Indicação a quem não comprou (0303): a Saída por falta de cobertura ou crédito negado pede indicação NA MESMA mensagem; o cliente manda o WhatsApp de alguém e a indicação é anotada sem reabrir a venda; em luto não se pede; a resposta honesta não repete em 12 h
-- tipo: atual
select sim.lead_com_venda('Feli X36') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'viabilidade', '{"resultado":"sem_viabilidade"}');
select public.lead_sair(:'c', null, 'fachada_nao_atendida');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('o aviso da Saída já leva o pedido de indicação (uma mensagem só)',
  (select count(*) from public.chatwoot_acoes a where a.conversa_id = :'c' and a.tipo = 'mensagem'
     and a.payload ->> 'texto_chave' in ('saida_sem_cobertura', 'saida_sem_cobertura_indicacao')) = 1
  and exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.payload ->> 'texto_chave' = 'saida_sem_cobertura_indicacao'),
  (select string_agg(a.payload ->> 'texto_chave', ', ') from public.chatwoot_acoes a where a.conversa_id = :'c' and a.tipo = 'mensagem'));
select sim.confere('o pedido de indicação ficou anotado', exists (select 1 from public.indicacao_pedidos p where p.conversa_id = :'c' and p.estado = 'pediu'
  and p.motivo = 'saida_sem_cobertura'), '');

-- uma hora depois ele indica a irmã
select sim.passa(:'c', '1 hour');
select sim.cliente_escreve(:'c', 'Minha irmã Joana mora no centro, o zap dela é 31 98877-6655') as r1 \gset
select sim.fila_rodar();
select sim.confere('a Mari não reabre a venda', :'r1' like 'calada%', :'r1');
select sim.confere('a venda continua em Saída', (select status = 'saida' from public.vendas where id = sim.venda(:'c')), '');
select sim.confere('a indicação foi anotada, de quem indicou e sem prêmio ainda',
  exists (select 1 from public.indicacoes i where i.indicador_conversa_id = :'c' and i.tel_chave = '3188776655' and i.premio_status = 'nenhum'
            and i.pedido_id is not null),
  (select string_agg(i.tel_chave || '/' || i.estado, ', ') from public.indicacoes i where i.indicador_conversa_id = :'c'));
select sim.confere('ele recebeu o "Anotado, obrigada!" e não a resposta de falta de cobertura de novo',
  exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.payload ->> 'texto_chave' = 'indicacao_obrigado')
  and (select count(*) from public.chatwoot_acoes a where a.conversa_id = :'c' and a.payload ->> 'texto_chave' = 'saida_sem_cobertura') = 0,
  (select string_agg(a.payload ->> 'texto_chave', ', ') from public.chatwoot_acoes a where a.conversa_id = :'c' and a.tipo = 'mensagem'));
select sim.confere('o pedido virou "recebeu"', (select estado from public.indicacao_pedidos p where p.conversa_id = :'c' order by pedido_em desc limit 1) = 'recebeu', '');
select sim.confere('a indicação aparece em Pagamentos (v_indicacoes), mesmo sem compra de quem indicou',
  exists (select 1 from public.v_indicacoes v where v.indicador_conversa_id = :'c'), '');

-- lead sem venda, Saída "Cidade não atendida": pede também; escreveu logo depois → a resposta honesta não repete em 12 h
select sim.lead_novo('Guto X36') as c2 \gset
select sim.como('backoffice');
select public.lead_sair(:'c2', null, 'cidade_nao_atendida');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('sem venda: o aviso também leva o pedido',
  exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c2' and a.payload ->> 'texto_chave' = 'saida_sem_cobertura_indicacao'), '');
select sim.cliente_escreve(:'c2', 'Que pena, obrigado') as r2 \gset
select sim.passa(:'c2', '40 minutes');
select sim.cliente_escreve(:'c2', 'Mas não tem previsão de chegar aqui?') as r3 \gset
select sim.fila_rodar();
select sim.confere('em menos de 12 h a resposta honesta não sai de novo (o aviso acabou de sair)',
  (select count(*) from public.chatwoot_acoes a where a.conversa_id = :'c2' and a.tipo = 'mensagem'
     and a.payload ->> 'texto_chave' in ('saida_sem_cobertura', 'saida_sem_cobertura_indicacao')) = 1,
  (select string_agg(a.payload ->> 'texto_chave', ', ') from public.chatwoot_acoes a where a.conversa_id = :'c2' and a.tipo = 'mensagem'));

-- em luto não se pede indicação
select sim.lead_novo('Lu X36', 'Oi, meu pai faleceu e quero ver internet para a casa da minha mãe') as c3 \gset
select sim.como('backoffice');
select public.lead_sair(:'c3', null, 'cidade_nao_atendida');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('em luto: o aviso sai sem o pedido de indicação',
  exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c3' and a.payload ->> 'texto_chave' = 'saida_sem_cobertura')
  and not exists (select 1 from public.indicacao_pedidos p where p.conversa_id = :'c3'),
  (select string_agg(a.payload ->> 'texto_chave', ', ') from public.chatwoot_acoes a where a.conversa_id = :'c3' and a.tipo = 'mensagem'));

-- crédito negado (Ricardo, 18/11 ~23h): a Saída, que não mandava nada, avisa com educação e pede indicação na mesma mensagem
select sim.lead_novo('Cid X36') as c4 \gset
select sim.como('backoffice');
select public.lead_sair(:'c4', null, 'credito_negado');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('crédito negado: sai 1 aviso com o pedido de indicação',
  (select count(*) from public.chatwoot_acoes a where a.conversa_id = :'c4' and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'saida_credito_indicacao') = 1
  and exists (select 1 from public.indicacao_pedidos p where p.conversa_id = :'c4' and p.motivo = 'saida_credito' and p.estado = 'pediu'),
  (select string_agg(a.payload ->> 'texto_chave', ', ') from public.chatwoot_acoes a where a.conversa_id = :'c4' and a.tipo = 'mensagem'));
select sim.passa(:'c4', '2 hours');
select sim.cliente_escreve(:'c4', 'Tenta com o meu primo Marcos, 32 98765-4321') as r4 \gset
select sim.fila_rodar();
select sim.confere('ele indicou: a Mari não reabre a conversa', :'r4' like 'calada%', :'r4');
select sim.confere('o lead continua em Saída', sim.lead_de(:'c4') ->> 'destino' = 'saida', sim.lead_de(:'c4')::text);
select sim.confere('a indicação foi anotada e ele recebeu o obrigado',
  exists (select 1 from public.indicacoes i where i.indicador_conversa_id = :'c4' and i.tel_chave = '3287654321')
  and exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c4' and a.payload ->> 'texto_chave' = 'indicacao_obrigado'), '');
