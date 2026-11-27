-- id: X150
-- titulo: Indicação reconhecida e registrada (0427, caso L-156 → L-397): o indicador responde ao pedido só com o nome → a Mari pede o WhatsApp ou que a pessoa chame, e guarda o nome; o lead que chega dizendo "fulana me passou seu contato" vira origem Indicação e é vinculado sozinho a quem indicou; o botão da ficha registra à mão; instalou → Pix previsto
-- tipo: atual
select sim.venda_pronta('Queroly X150') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '91' || sim._conv(:'c'), 'dia', (current_date + 2)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.passa(:'c', '2 days');
select sim.instalou(:'c');
select sim.espera(:'c', '90 minutes');
select sim.cliente_escreve(:'c', 'Deu tudo certo sim, obrigado!') as r0 \gset
select sim.fila_rodar();

-- pediu a indicação; ela responde "Blz" (insiste) e depois só o nome, sem telefone
select sim.cliente_escreve(:'c', 'Blz') as r1 \gset
select sim.fila_rodar();
select sim.confere('"Blz" não é nome: a Mari insiste uma vez',
  exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.payload ->> 'texto_chave' = 'indicacao_insistir')
  and not exists (select 1 from public.indicacao_pistas p where p.conversa_id = :'c'), '');
select sim.cliente_escreve(:'c', 'Rayra Piranha') as r2 \gset
select sim.cliente_escreve(:'c', 'Rayra') as r3 \gset
select sim.fila_rodar();
select sim.confere('nome sem telefone: a Mari pede o WhatsApp (ou que a pessoa chame), uma vez só',
  (select count(*) from public.chatwoot_acoes a where a.conversa_id = :'c' and a.payload ->> 'texto_chave' = 'indicacao_pedir_whats') = 1,
  (select count(*)::text from public.chatwoot_acoes a where a.conversa_id = :'c' and a.payload ->> 'texto_chave' = 'indicacao_pedir_whats'));
select sim.confere('o nome ficou guardado como pista e o pedido continua aberto',
  (select count(*) from public.indicacao_pistas p where p.conversa_id = :'c' and p.tipo = 'nome_do_indicado' and p.estado = 'aberta') = 1
  and exists (select 1 from public.pos_instalacao p where p.conversa_id = :'c' and p.estado = 'pediu'),
  (select string_agg(p.estado, ',') from public.pos_instalacao p where p.conversa_id = :'c'));

-- a indicada chega sozinha, por outro número, e diz quem passou o contato (grafia diferente do nome)
select sim.lead_novo('Rayra X150') as d \gset
select sim.cliente_escreve(:'d', 'A minha prima me passou seu contato keroly') as r4 \gset
select sim.confere('o lead que disse ter sido indicado vira origem Indicação',
  (select origem from public.mari_conversas where id = :'d') = 'indicacao', (select origem from public.mari_conversas where id = :'d'));
select sim.confere('a indicação nasce sozinha, ligada a quem indicou',
  exists (select 1 from public.indicacoes i where i.conversa_id = :'d' and i.indicador_conversa_id = :'c' and i.estado = 'contatada'),
  (select count(*)::text from public.indicacoes));
select sim.confere('as duas pistas fecharam',
  not exists (select 1 from public.indicacao_pistas p where p.conversa_id in (:'c', :'d') and p.estado = 'aberta'), '');

-- registrar de novo pelo botão não duplica; a prévia diz o que vai acontecer
select sim.como('backoffice');
select sim.confere('a prévia do botão não grava nada e diz o que vai desencadear',
  (public.indicacao_registrar(:'d', (select lead_numero::text from public.mari_conversas where id = :'c'), false) ->> 'previa')::boolean
  and (select count(*) from public.indicacoes i where i.conversa_id = :'d') = 1, '');
select sim.confere('confirmar de novo não duplica',
  (public.indicacao_registrar(:'d', (select lead_numero::text from public.mari_conversas where id = :'c'), true) ->> 'ja')::boolean
  and (select count(*) from public.indicacoes i where i.conversa_id = :'d') = 1, '');
select sim.como('vendedor');
select sim.confere('vendedor não registra indicação',
  coalesce(sim.recusa($q$ select public.indicacao_registrar('00000000-0000-0000-0000-000000000000', '1', false) $q$), '') like '%Só admin e backoffice%', '');

-- lead que diz ter sido indicado sem ninguém que bata: fica a pista para a conferência
select sim.lead_novo('Solto X150') as e \gset
select sim.cliente_escreve(:'e', 'Oi, um amigo me indicou vocês') as r5 \gset
select sim.confere('sem quem indicou: pista aberta, origem Indicação, nenhuma indicação criada',
  exists (select 1 from public.indicacao_pistas p where p.conversa_id = :'e' and p.tipo = 'disse_indicado' and p.estado = 'aberta')
  and not exists (select 1 from public.indicacoes i where i.conversa_id = :'e'), '');
