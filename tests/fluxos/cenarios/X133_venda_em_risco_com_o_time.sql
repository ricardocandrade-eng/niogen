-- id: X133
-- titulo: 0403: venda em risco também em conversa que já está com o time — plano escolhido, o cliente fala de pressa na instalação ou de desistir e ninguém respondeu ainda → 1º da fila da Live 2.0 com a fala no texto; "pode deixar" sozinho não conta com o time; sai quando a pessoa responde; live2_resgates conta (origem time)
-- tipo: atual
-- as frases (as mesmas do motor da Mari, P54)
select sim.confere('frases de pressa',
  public._risco_fala('Teria para hoje?', true, true) = 'pressa' and public._risco_fala('Consegue instalar ainda hoje', false, true) = 'pressa'
  and public._risco_fala('Estou precisando URGENTE de internet', false, true) = 'pressa' and public._risco_fala('dá pra ser hoje?', true, false) = 'pressa'
  and public._risco_fala('o quanto antes', false, false) = 'pressa', 'pressa');
select sim.confere('frases de desistência (só na hora de marcar)',
  public._risco_fala('Não quero mais', true, true) = 'desiste' and public._risco_fala('Pode cancelar não vou querer mais nao', true, true) = 'desiste'
  and public._risco_fala('Eu já tava quase desistindo', true, true) = 'desiste' and public._risco_fala('Então pode deixar obg', true, false) = 'desiste'
  and public._risco_fala('Não quero mais', false, true) is null, 'desiste');
select sim.confere('o que não é risco',
  public._risco_fala('Pode deixar', true, true) is null and public._risco_fala('Pode deixar de manhã', true, false) is null
  and public._risco_fala('Hoje mesmo te mando o CPF', false, true) is null and public._risco_fala('Manhã', true, true) is null
  and public._risco_fala('quero o plano mais rápido', true, true) is null and public._risco_fala('Sim', true, true) is null
  and public._risco_fala('hoje eu pago 120 na outra', true, true) is null, 'controles');

-- um lead que já espera resposta (urgência 4) e o lead do caso, com o time e com plano e forma escolhidos
select sim.lead_novo('Bia X133') as b \gset
select sim.mari_handoff(:'b', 'pedido_humano');
select sim.fila_rodar();
select sim.lead_novo('Davi X133') as c \gset
select sim.como('backoffice');
select public.backoffice_conversa(:'c', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi, Davi! Vamos seguir com o seu pedido?');
select sim.fila_rodar();
select sim.como('servico');
update public.mari_conversas set plano_escolhido = (select codigo from public.config_planos where ativo order by preco limit 1), forma_pagamento = 'boleto' where id = :'c';

-- 1) fala comum: é Responder, sem risco
select sim.cliente_escreve(:'c', 'Pode ser, qual o próximo passo?', false);
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'c'), '{}') as l0 \gset
select sim.confere('fala comum do cliente: Responder, sem risco', (:'l0')::jsonb ->> 'tipo' = 'responder' and not ((:'l0')::jsonb ->> 'risco')::boolean, left(:'l0', 300));

-- 2) pressa na instalação: 1º da fila, com a fala
select sim.como('servico');
select sim.cliente_escreve(:'c', 'Consegue instalar hoje?', false);
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce(((:'f')::jsonb -> 'fila' -> 0)::text, '{}') as l1 \gset
select sim.confere('com o time e com pressa: é a 1ª da fila, urgência 5',
  (:'l1')::jsonb ->> 'conversa_id' = :'c' and ((:'l1')::jsonb ->> 'risco')::boolean and ((:'l1')::jsonb ->> 'urg')::int = 5 and (:'l1')::jsonb ->> 'tipo' = 'responder', left(:'l1', 300));
select sim.confere('o texto traz o tipo e a fala do cliente',
  (:'l1')::jsonb ->> 'oque' like 'Venda em risco · o cliente quer a instalação para já%«Consegue instalar hoje?»', (:'l1')::jsonb ->> 'oque');

-- 3) "Pode deixar" para uma pessoa não é desistência
select sim.como('servico');
select sim.cliente_escreve(:'c', 'Pode deixar', false);
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select sim.confere('"Pode deixar" com o time não marca risco',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'c' and (x ->> 'risco')::boolean), (:'f')::jsonb ->> 'conta');

-- 4) ameaça de desistir: volta a ser risco; a pessoa responde e sai
select sim.como('servico');
select sim.cliente_escreve(:'c', 'Assim não dá, não quero mais', false);
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce(((:'f')::jsonb -> 'fila' -> 0)::text, '{}') as l2 \gset
select sim.confere('falou em desistir: 1ª da fila, tipo desistência',
  (:'l2')::jsonb ->> 'conversa_id' = :'c' and ((:'l2')::jsonb ->> 'risco')::boolean and (:'l2')::jsonb ->> 'oque' like 'Venda em risco · o cliente falou em desistir%', left(:'l2', 300));
select public.backoffice_responder(:'c', 'Calma, Davi! Me conta o que não serviu que eu resolvo agora.');
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select sim.confere('a pessoa respondeu: sai da regra do risco',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'c' and (x ->> 'risco')::boolean)
  and ((:'f')::jsonb -> 'conta' ->> 'em_risco')::int = 0, (:'f')::jsonb ->> 'conta');

-- 5) a medição conta o caso com o time e os minutos da resposta
select public.live2_resgates(30)::text as m \gset
select coalesce((select x::text from jsonb_array_elements((:'m')::jsonb -> 'lista') x where x ->> 'conversa_id' = :'c'), '{}') as r1 \gset
select sim.confere('a medição conta a fala com o time e os minutos',
  (:'r1')::jsonb ->> 'origem' = 'time' and (:'r1')::jsonb ->> 'tipo' = 'pressa' and ((:'r1')::jsonb ->> 'minutos')::int >= 0
  and ((:'m')::jsonb ->> 'com_o_time')::int >= 1, left(:'m', 300));
