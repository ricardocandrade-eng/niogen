-- id: X165
-- titulo: 0443 (L-132 Lígia #117, 28/11): em Saída definitiva por crédito negado ou biometria reprovada, quem volta a escrever fala com a Mari (sem "já chamei o time"); "obrigada" segue em silêncio; a Mari passa ao time pelo handoff; "Nio não instalou" (L-82) continua calada; ligado=false devolve à fala fixa
-- tipo: atual

-- 1) crédito negado; dias depois pergunta do chip → a Mari responde, sem fala fixa; a situação não muda
select sim.lead_com_venda('Ligia X165') as c \gset
select sim.como('backoffice');
select public.lead_sair(:'c', sim.venda(:'c'), 'credito_negado', 'só cartão, sem cartão', null, null, false);
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('Saída definitiva', public._porta_situacao(:'c', null::uuid) = 'saida_definitiva', public._porta_situacao(:'c', null::uuid));
select sim.passa(:'c', '4 days');
select sim.cliente_escreve(:'c', 'Esse plano da nio, o chip é da operadora tim?') as r1 \gset
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('crédito negado: a Mari responde', :'r1' = 'respondeu', :'r1');
select sim.confere('sem a fala fixa "já chamei o time"', not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c'
  and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'volta_ao_time'), null);
select sim.confere('o lead continua na Saída definitiva', public._porta_situacao(:'c', null::uuid) = 'saida_definitiva', public._porta_situacao(:'c', null::uuid));
select sim.espera(:'c', '20 minutes');
select sim.como('servico');
select sim.confere('sem mais nada, a varredura fecha a conversa', (sim.cw_de(:'c') ->> 'status') = 'resolved', sim.cw_de(:'c')::text);

-- 2) "Obrigada" solto → silêncio, como antes
select sim.cliente_escreve(:'c', 'Obrigada') as r2 \gset
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('"Obrigada": a Mari fica calada', :'r2' like 'calada:%', :'r2');
select sim.confere('"Obrigada" não chama o time', not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c'
  and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'volta_ao_time'), null);

-- 3) caminho novo → a Mari responde e passa ao time: é a volta ao time (0383), sem time dono nem etiqueta de handoff no lead em Saída
select sim.cliente_escreve(:'c', 'Minha filha tem cartão de crédito, dá pra fazer no nome dela?', true, '2 hours') as r3 \gset
select sim.confere('caminho novo: a Mari responde', :'r3' = 'respondeu', :'r3');
select sim._servico();
select public.mari_handoff(:'c', 'pedido_humano', '{"briefing": "RESUMO: quer fazer no nome da filha, que tem cartão de crédito."}'::jsonb) as h3 \gset
select public.mari_chatwoot_pedir(sim._conv(:'c'), 'handoff_humano', '🟡 PEDIU ATENDIMENTO · quer fazer no nome da filha') as p3 \gset
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('o handoff virou volta ao time', coalesce((:'h3'::jsonb ->> 'volta_ao_time')::boolean, false), :'h3');
select sim.confere('o cliente ouviu "já chamei o time"', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c'
  and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'volta_ao_time'), null);
select sim.confere('o pedido do nó 9e só grava a nota', :'p3'::jsonb -> 'feito' = '["nota"]'::jsonb, :'p3');
select sim.confere('sem time dono e sem etiqueta de handoff', not coalesce((select time_atribuido from public.mari_conversas where id = :'c'), false)
  and not (sim.cw_de(:'c') -> 'etiquetas' ? 'handoff-humano'), sim.cw_de(:'c')::text);
select sim.confere('a conversa está aberta para o time', (sim.cw_de(:'c') ->> 'status') = 'open', sim.cw_de(:'c')::text);
select sim.confere('o lead continua na Saída definitiva', public._porta_situacao(:'c', null::uuid) = 'saida_definitiva', public._porta_situacao(:'c', null::uuid));
select sim.espera(:'c', '30 minutes');
select sim.como('servico');
select sim.confere('30 min depois continua aberta (espera uma pessoa)', (sim.cw_de(:'c') ->> 'status') = 'open', sim.cw_de(:'c')::text);
select sim.confere('e o alarme diz que é vez do time', coalesce((select s.vez_do_time from public.v_mari_sem_resposta s where s.id = :'c'), false), null);
select sim.time_fala_no_chatwoot(:'c', 'Oi, Lígia! Dá sim, me passa o nome e o CPF dela?');
select sim.fila_rodar();
select sim.como('servico');

-- 4) "Nio não instalou" (o caso L-82) continua com a fala fixa e o time
select sim.lead_com_venda('Michele X165') as d \gset
select sim.como('backoffice');
select public.lead_sair(:'d', sim.venda(:'d'), 'nio_nao_instalou', 'outro', null, null, false);
select sim.fila_rodar();
select sim.como('servico');
select sim.passa(:'d', '4 days');
select sim.cliente_escreve(:'d', 'O outro foi dado baixa') as r4 \gset
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('Nio não instalou: a Mari continua calada', :'r4' like 'calada: banco%', :'r4');
select sim.confere('Nio não instalou: fala fixa de volta ao time', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'d'
  and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'volta_ao_time'), null);
select sim.time_fala_no_chatwoot(:'d', 'Oi, Michele! Vou conferir aqui.');
select sim.fila_rodar();
select sim.como('servico');

-- 5) desligado na config → crédito negado volta à fala fixa (o caminho de volta sem deploy)
update public.config_regras set valor = jsonb_set(valor, '{ligado}', 'false') where chave = 'mari_retoma_saida';
select sim.lead_com_venda('Cida X165') as e \gset
select sim.como('backoffice');
select public.lead_sair(:'e', sim.venda(:'e'), 'credito_negado', 'só cartão, sem cartão', null, null, false);
select sim.fila_rodar();
select sim.como('servico');
select sim.passa(:'e', '4 days');
select sim.cliente_escreve(:'e', 'Quanto fica o plano de 1 giga?') as r5 \gset
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('desligado: a Mari volta a calar', :'r5' like 'calada: banco%', :'r5');
select sim.confere('desligado: fala fixa de volta ao time', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'e'
  and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'volta_ao_time'), null);
select sim.time_fala_no_chatwoot(:'e', 'Oi! O de 1 Giga sai R$ 170 no boleto.');
select sim.fila_rodar();
select sim.como('servico');
update public.config_regras set valor = jsonb_set(valor, '{ligado}', 'true') where chave = 'mari_retoma_saida';
