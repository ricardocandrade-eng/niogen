-- id: X128
-- titulo: 0398 (caso L-287): na Live 2.0, quando a última fala do cliente é uma recusa ("Não obrigada") e o time já respondeu, a linha vira Decidir — "O cliente recusou · registrar a Saída", urgência 1, botão Registrar a Saída — em vez de mandar cobrar ou conferir; antes de o time responder continua Responder; se o cliente escrever de novo, deixa de ser recusa
-- tipo: atual
select sim.lead_novo('Rita X128') as c \gset
select sim.como('backoffice');
select public.backoffice_conversa(:'c', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi, Rita! Vamos seguir com o pedido?');
select sim.fila_rodar();
select sim.como('servico');
select sim.cliente_escreve(:'c', 'Não obrigada', false);
select sim.fila_rodar();

-- 1) o time ainda não respondeu à recusa: é Responder
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'c'), '{}') as l1 \gset
select sim.confere('recusa sem resposta do time ainda é Responder', (:'l1')::jsonb ->> 'tipo' = 'responder' and not coalesce(((:'l1')::jsonb ->> 'recusa')::boolean, false), left(:'l1', 300));

-- 2) o time se despede; na manhã seguinte o prazo de cutucar vence: a linha é "o cliente recusou", não cobrança
select public.backoffice_responder(:'c', 'Que pena! Se mudar de ideia, pode contar comigo.');
select sim.fila_rodar();
select sim.como('servico');
select sim.passa(:'c', '14 hours');
select sim.tique();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'c'), '{}') as l2 \gset
select sim.confere('a linha vira Decidir com a fala do cliente no texto',
  ((:'l2')::jsonb ->> 'recusa')::boolean and (:'l2')::jsonb ->> 'tipo' = 'decidir' and (:'l2')::jsonb ->> 'oque' like 'O cliente recusou: «Não obrigada»%', left(:'l2', 400));
select sim.confere('urgência 1 e o botão Registrar a Saída na frente',
  ((:'l2')::jsonb ->> 'urg')::int = 1
  and exists (select 1 from jsonb_array_elements((:'l2')::jsonb -> 'acoes') y where y ->> 'a' = 'saida' and (y ->> 'principal')::boolean), (:'l2')::jsonb ->> 'acoes');

-- 3) o cliente volta a falar: deixa de ser recusa
select sim.como('servico');
select sim.cliente_escreve(:'c', 'Pensando bem, quanto fica o plano de 600 mega?', false);
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'c'), '{}') as l3 \gset
select sim.confere('cliente escreveu de novo → volta a ser Responder, sem recusa',
  (:'l3')::jsonb ->> 'tipo' = 'responder' and not ((:'l3')::jsonb ->> 'recusa')::boolean, left(:'l3', 300));
