-- id: X106
-- titulo: 0383 (L-82, Michele, #76): quem volta a escrever em Saída definitiva, em Saída "Já tem pedido Nio" ou com a venda na instalação não fala com a Mari — recebe uma fala fixa e a conversa abre para o time; Saída nova "Já tem pedido Nio no CPF" e "no endereço"; o portal "pedido no endereço" não vira "sem viabilidade"
-- tipo: regra_nova
-- 1) Michele: Saída "Nio não instalou" e, 4 dias depois, "Oiii" → a Mari não responde; sai a fala fixa e a conversa abre para o time
select sim.lead_com_venda('Michele X106') as c \gset
select sim.como('backoffice');
select public.lead_sair(:'c', sim.venda(:'c'), 'nio_nao_instalou', 'outro', null, null, false);
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('Saída definitiva', public._porta_situacao(:'c', null::uuid) = 'saida_definitiva', public._porta_situacao(:'c', null::uuid));
select sim.passa(:'c', '4 days');
select sim.cliente_escreve(:'c', 'Oiii') as r1 \gset
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('a Mari não responde (banco)', :'r1' like 'calada: banco%', :'r1');
select coalesce((select a.payload ->> 'texto_chave' from public.chatwoot_acoes a
  where a.conversa_id = :'c' and a.tipo = 'mensagem' order by a.id desc limit 1), 'nada') as k1 \gset
select sim.confere('sai a fala fixa de volta ao time', :'k1' = 'volta_ao_time', :'k1');
select sim.confere('a conversa abre no Chatwoot para o time', (sim.cw_de(:'c') ->> 'status') = 'open', sim.cw_de(:'c')::text);
select sim.passa(:'c', '10 minutes');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('e continua aberta depois do eco da fala fixa (não refecha)', (sim.cw_de(:'c') ->> 'status') = 'open', sim.cw_de(:'c')::text);
select sim.confere('o lead continua na Saída definitiva', public._porta_situacao(:'c', null::uuid) = 'saida_definitiva', public._porta_situacao(:'c', null::uuid));
-- logo depois ela escreve de novo: nada de Mari, e a fala fixa não repete
select sim.cliente_escreve(:'c', 'O outro foi dado baixa') as r2 \gset
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('2ª fala: a Mari continua calada', :'r2' like 'calada:%', :'r2');
select sim.confere('a fala fixa sai uma vez só', (select count(*) from public.chatwoot_acoes a where a.conversa_id = :'c'
  and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'volta_ao_time') = 1,
  (select count(*)::text from public.chatwoot_acoes a where a.conversa_id = :'c' and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'volta_ao_time'));
-- ninguém pegou em 24 h: o prazo da 0335 (fora_fechar) fecha de novo — a rotina de prazos faria isso sozinha
select sim.passa(:'c', '25 hours');
select public.porta('prazo:fora_fechar', :'c', null::uuid);
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('parada 24 h, a conversa volta a fechar', (sim.cw_de(:'c') ->> 'status') = 'resolved', sim.cw_de(:'c')::text);

-- 2) Saída "Já tem pedido Nio no endereço" (conversa sem venda): pode voltar quando o pedido de lá cair, mas a volta é com o time
select sim.lead_pronto('Endereco X106') as c2 \gset
select sim.como('backoffice');
select public.lead_sair(:'c2', null, 'pedido_nio_endereco');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('motivo novo existe e é "pode voltar"', public._porta_situacao(:'c2', null::uuid) = 'saida_pode_voltar', public._porta_situacao(:'c2', null::uuid));
select sim.confere('o destino da conversa é pedido_nio', (select funil_destino from public.mari_conversas where id = :'c2') = 'pedido_nio',
  (select funil_destino from public.mari_conversas where id = :'c2'));
select sim.confere('o lead guarda o motivo', sim.lead_de(:'c2') ->> 'saida' = 'pedido_nio_endereco', sim.lead_de(:'c2')::text);
select sim.passa(:'c2', '1 day');
select sim.cliente_escreve(:'c2', 'E aí, já dá pra pedir?') as r3 \gset
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('pedido Nio: a Mari não reabre a venda', :'r3' like 'calada: banco%', :'r3');
select sim.confere('pedido Nio: fala fixa de volta ao time', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c2'
  and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'volta_ao_time'), null);
select sim.confere('pedido Nio: o lead segue na Saída', sim.lead_de(:'c2') ->> 'destino' = 'saida', sim.lead_de(:'c2')::text);
select sim.passa(:'c2', '25 hours');
select public.porta('prazo:fora_fechar', :'c2', null::uuid);
select sim.fila_rodar();
select sim.como('servico');

-- 3) "Já tem pedido Nio no CPF" também existe e não é "cliente Nio" (não silencia)
select sim.lead_pronto('CPF X106') as c3 \gset
select sim.como('backoffice');
select public.lead_sair(:'c3', null, 'pedido_nio_cpf');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('pedido no CPF: pode voltar, não é cliente Nio', public._porta_situacao(:'c3', null::uuid) = 'saida_pode_voltar', public._porta_situacao(:'c3', null::uuid));

-- 4) venda na instalação (aguardando a Nio), conversa de volta à Mari: pergunta do cliente vai para o time
select sim.venda_pronta('Instalacao X106') as c4 \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c4'), 'os_agendar', jsonb_build_object('os', '97' || sim._conv(:'c4'), 'dia', (current_date + 4)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.como('servico');
update public.mari_conversas set status = 'ativo', etapa = 'retomada', handoff_motivo = null, humano_atribuido = false where id = :'c4';
update sim.cw set agente = null, time_nome = null, status = 'resolved' where conv = sim._conv(:'c4');
select public._porta_situacao(:'c4', null::uuid) as s4 \gset
select sim.passa(:'c4', '1 day');
select sim.cliente_escreve(:'c4', 'Que horas o técnico vem?') as r4 \gset
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('instalação: a Mari não responde', :'r4' like 'calada: banco%', :'s4' || ' / ' || :'r4');
select sim.confere('instalação: fala fixa de volta ao time', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c4'
  and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'volta_ao_time'), :'s4');

-- 5) Recusou continua reabrindo com a Mari (não muda)
select sim.lead_pronto('Recusou X106') as c5 \gset
select sim.como('backoffice');
select public.lead_sair(:'c5', null, 'recusou', 'preço');
select sim.fila_rodar();
select sim.como('servico');
select sim.passa(:'c5', '1 day');
select sim.cliente_escreve(:'c5', 'Pensei melhor, quero ver os planos') as r5 \gset
select sim.confere('recusou: a Mari responde como antes', :'r5' = 'respondeu', :'r5');

-- 6) operador: popup "pedido em andamento para o endereço" na viabilidade → marca pedido no endereço, não "sem cobertura"
select sim.lead_pronto('Viab X106') as c6 \gset
select sim.como('servico');
select public.mari_viab_gravar(:'c6', '{"resultado":"pedido_endereco","popup":{"titulo":"Indisponível","texto":"já existe um pedido (Nova Fibra) em andamento para o endereço informado"}}'::jsonb);
select sim.confere('viabilidade: pedido no endereço marcado', (select nio_pedido_aberto from public.mari_conversas where id = :'c6') = 'endereco',
  (select coalesce(nio_pedido_aberto, 'null') from public.mari_conversas where id = :'c6'));
select sim.confere('viabilidade: não vira sem cobertura', coalesce((select cobertura_decisao from public.mari_conversas where id = :'c6'), '') <> 'sem_cobertura',
  (select coalesce(cobertura_decisao, 'null') from public.mari_conversas where id = :'c6'));

-- 7) crédito: o mesmo popup no modo crédito grava "pedido no endereço" (e o do CPF segue como antes)
select sim.lead_pronto('Cred X106') as c7 \gset
select sim.como('servico');
select public.mari_credito_gravar(:'c7', '{"resultado":"pedido_endereco"}'::jsonb);
select sim.confere('crédito: pedido no endereço', (select credito_resultado || '/' || nio_pedido_aberto from public.mari_conversas where id = :'c7') = 'pedido_endereco/endereco',
  (select coalesce(credito_resultado, 'null') || '/' || coalesce(nio_pedido_aberto, 'null') from public.mari_conversas where id = :'c7'));
select public.mari_credito_gravar(:'c7', '{"resultado":"pedido_em_andamento"}'::jsonb);
select sim.confere('crédito: pedido no CPF continua "sim"', (select nio_pedido_aberto from public.mari_conversas where id = :'c7') = 'sim', null);
