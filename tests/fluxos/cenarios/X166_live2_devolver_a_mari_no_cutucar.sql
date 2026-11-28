-- id: X166
-- titulo: 0444 (Ricardo, 28/11: "Sim, os três" — caso Vivian): na Live 2.0, o cartão "Cutucar o cliente" (o time respondeu e o cliente ficou calado) ganha o botão "Devolver à Mari", ao lado do Responder — a conversa passa para a Mari e a linha sai da fila; tarefa comum de Responder (o cliente escreveu) não ganha o botão
-- tipo: atual
select sim.como('servico');
insert into public.config_regras (chave, valor, descricao) values
  ('time_horario', '{"1": [0, 24], "2": [0, 24], "3": [0, 24], "4": [0, 24], "5": [0, 24], "6": [0, 24], "7": [0, 24]}'::jsonb, 'X166: time aberto o dia todo')
on conflict (chave) do update set valor = excluded.valor;

-- ───────── o cartão "Cutucar o cliente" tem "Devolver à Mari" ─────────
select sim.lead_novo('Vivian X166') as c \gset
select sim.mari_fala(:'c', 'Oi! Sou a Mari, da Nio. Qual o seu CEP?');
select sim.como('backoffice');
select public.backoffice_conversa(:'c', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('servico');
select sim.cliente_escreve(:'c', 'Tem dados móveis?', false);
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Boa noite, Vivian! Temos ótimas opções de planos com chip, preço congelado até 2030.');
select sim.fila_rodar();
select sim.como('servico');
select sim.tique();
select sim.espera(:'c', '3 hours 10 minutes');
select sim.tique();
-- um lead comum: assumido pelo time e o cliente acabou de escrever
select sim.lead_novo('Olga X166') as b \gset
select sim.mari_fala(:'b', 'Oi! Sou a Mari, da Nio. Qual o seu CEP?');
select sim.como('backoffice');
select public.backoffice_conversa(:'b', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('servico');
select sim.cliente_escreve(:'b', 'Qual o valor do plano de 700 mega?', false);
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'c'), '{}') as lc \gset
select sim.confere('3 h depois da resposta do time, a linha é "Cutucar o cliente"',
  (:'lc')::jsonb ->> 'oque' like 'Cutucar o cliente%', left(:'lc', 400));
select sim.confere('o cartão da cutucada tem o botão "Devolver à Mari", além do Responder',
  exists (select 1 from jsonb_array_elements((:'lc')::jsonb -> 'acoes') a
           where a ->> 'a' = 'rpc' and a ->> 'fn' = 'backoffice_momento' and a -> 'args' ->> 'p_momento' = 'devolver_mari'
             and a -> 'args' -> 'p_dados' ->> 'conversa_id' = :'c' and coalesce(a ->> 'confirma', '') <> '')
  and exists (select 1 from jsonb_array_elements((:'lc')::jsonb -> 'acoes') a where a ->> 'a' = 'abrir' and (a ->> 'principal')::boolean),
  ((:'lc')::jsonb -> 'acoes')::text);
select sim.confere('tarefa de Responder comum (cliente escreveu) está na fila e não ganha o botão',
  exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'b' and x ->> 'tipo' = 'responder')
  and not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x, jsonb_array_elements(x -> 'acoes') a
               where x ->> 'conversa_id' = :'b' and a ->> 'fn' = 'backoffice_momento'),
  (select left(x::text, 300) from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'b'));

-- o clique: a conversa vai para a Mari e a linha sai
select public.backoffice_momento(null, 'devolver_mari', jsonb_build_object('conversa_id', :'c'));
select sim.fila_rodar();
select public.live2_fila()::text as f \gset
select sim.confere('depois de "Devolver à Mari", a conversa está com a Mari e a linha saiu da fila',
  (select situacao = 'mari_atendendo' from public.lead_estado where conversa_id = :'c' and venda_id is null)
  and not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'c'),
  (select situacao from public.lead_estado where conversa_id = :'c' and venda_id is null));
