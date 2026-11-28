-- id: X144
-- titulo: 0420 (L-132 Lígia #117 e L-220 Cidinha #200, 26/11): em Saída definitiva, quem ouviu "já chamei o time" fica com a conversa aberta até alguém do time responder, e o alarme diz que é com o TIME; "Não"/"Sim" soltos não chamam o time nem tocam o alarme
-- tipo: atual
insert into public.config_regras (chave, valor, descricao) values ('resumo_destino_whatsapp', '"5500000000001"', 'sim X144')
on conflict (chave) do nothing;

-- 1) Lígia: Saída definitiva; dias depois escreve de verdade → fala fixa, e a conversa NÃO fecha nas varreduras de 10 min
-- (28/11, 0443: em crédito negado a Mari passou a responder — este passo usa "Nio não instalou", que segue com a fala fixa)
select sim.lead_com_venda('Ligia X144') as c \gset
select sim.como('backoffice');
select public.lead_sair(:'c', sim.venda(:'c'), 'nio_nao_instalou', 'outro', null, null, false);
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('Saída definitiva', public._porta_situacao(:'c', null::uuid) = 'saida_definitiva', public._porta_situacao(:'c', null::uuid));
select sim.passa(:'c', '4 days');
select sim.cliente_escreve(:'c', 'Sou cliente, tô esperando o chip') as r1 \gset
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('a Mari não responde', :'r1' like 'calada: banco%', :'r1');
select sim.confere('ele ouviu "já chamei o time"', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c'
  and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'volta_ao_time'), null);
select sim.espera(:'c', '30 minutes');
select sim.como('servico');
select sim.confere('30 min e 3 varreduras depois, a conversa segue aberta para o time', (sim.cw_de(:'c') ->> 'status') = 'open', sim.cw_de(:'c')::text);
select sim.confere('o alarme enxerga a espera, marcada como vez do time',
  coalesce((select s.vez_do_time from public.v_mari_sem_resposta s where s.id = :'c'), false),
  (select count(*)::text from public.v_mari_sem_resposta s where s.id = :'c'));
select public.mari_alarme_proximos() as al \gset
select sim.confere('o aviso no WhatsApp diz que é com o TIME',
  exists (select 1 from jsonb_array_elements(:'al'::jsonb) e where e -> 'params' ->> 1 = sim._conv(:'c') and e -> 'params' ->> 2 like '%TIME%'), :'al');
-- alguém do time responde: o episódio acaba
select sim.time_fala_no_chatwoot(:'c', 'Boa tarde, Lígia! Você já é cliente da Nio?');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('o time respondeu: sai do alarme', not exists (select 1 from public.v_mari_sem_resposta s where s.id = :'c'), null);

-- 2) Cidinha: Saída com pedido de indicação; "Nao" e "Sim" soltos → silêncio, sem "já chamei o time", sem alarme, e a conversa fecha
select sim.lead_com_venda('Cida X144') as d \gset
select sim.como('backoffice');
select public.lead_sair(:'d', sim.venda(:'d'), 'credito_negado', 'só cartão, sem cartão', null, null, false);
select sim.fila_rodar();
select sim.como('servico');
select sim.passa(:'d', '7 minutes');
select sim.cliente_escreve(:'d', 'Nao') as r2 \gset
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('"Nao": a Mari fica calada', :'r2' like 'calada:%', :'r2');
select sim.confere('"Nao" não chama o time', not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'d'
  and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'volta_ao_time'), null);
select sim.cliente_escreve(:'d', 'Sim', true, '30 seconds') as r3 \gset
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('"Sim": idem', :'r3' like 'calada:%' and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'d'
  and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'volta_ao_time'), :'r3');
select sim.passa(:'d', '4 minutes');
select sim.confere('4 min depois, nenhum alarme', not exists (select 1 from public.v_mari_sem_resposta s where s.id = :'d'), null);
select sim.espera(:'d', '10 minutes');
select sim.como('servico');
select sim.confere('e a varredura fecha a conversa', (sim.cw_de(:'d') ->> 'status') = 'resolved', sim.cw_de(:'d')::text);

-- 3) o alarme de verdade não muda: lead em andamento, a Mari devia responder e não respondeu
select sim.lead_pronto('Real X144') as e \gset
select sim.cliente_escreve(:'e', 'Quanto fica o plano de 1 giga?', false) as r4 \gset
select sim.como('servico');
select sim.passa(:'e', '4 minutes');
select sim.confere('Mari calada em andamento: alarma, e não é "vez do time"',
  exists (select 1 from public.v_mari_sem_resposta s where s.id = :'e' and not s.vez_do_time), :'r4');
select sim.mari_fala(:'e', 'O Super de 1 Giga sai R$ 170 no boleto.');
