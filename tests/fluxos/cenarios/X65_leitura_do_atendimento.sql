-- id: X65
-- titulo: 0339 (21/11): a leitura do atendimento pelas mensagens — cliente sem resposta vira "esperando nós" e cai no Conferir; respondido vira conversa viva; o time falando por último nunca é "esperando nós"
-- tipo: atual
-- Caso: diagnóstico do agente de tráfego (18/11) leu "35 leads parados do nosso lado" pela vez; mensagem a mensagem, eram 0.
select sim.lead_novo('Bia X65') as c \gset
select sim.como('servico');
select coalesce((select caixa from public.v_atendimento_fatos where conversa_id = :'c'), '') as k0 \gset
select sim.confere('lead novo respondido pela Mari: conversa viva', :'k0' = 'conversa_viva', :'k0');

-- (a) o cliente pergunta e ninguém responde por 20 min
select sim.cliente_escreve(:'c', 'qual o preço do plano de 600?', false);
select sim.espera(:'c', '20 minutes');
select sim.como('servico');
select coalesce((select caixa || ':' || coalesce(esperando_nos_min::text, '') from public.v_atendimento_fatos where conversa_id = :'c'), '') as k1 \gset
select sim.confere('cliente sem resposta: esperando nós, com os minutos', :'k1' like 'esperando_nos:%' and split_part(:'k1', ':', 2)::int >= 15, :'k1');
select coalesce((select (x ->> 'n')::int from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'esperando_nos'), -1) as n1 \gset
select sim.confere('o Conferir aponta o cliente sem resposta (falha)', :n1 >= 1, :'n1');
select coalesce((select (public.atendimento_leitura(now() - interval '1 day') -> 'esperando_nos')::int), -1) as r1 \gset
select sim.confere('o resumo conta o esperando nós', :r1 >= 1, :'r1');

-- (b) a Mari responde: volta a conversa viva, sai do Conferir
select sim.mari_fala(:'c', 'O de 600 Mega sai por R$ 95 no cartão. Me passa o seu CEP?');
select coalesce((select caixa from public.v_atendimento_fatos where conversa_id = :'c'), '') as k2 \gset
select sim.confere('respondido: conversa viva', :'k2' = 'conversa_viva', :'k2');
select coalesce((select count(*) from public.v_atendimento_fatos where conversa_id = :'c' and caixa = 'esperando_nos'), -1) as n2 \gset
select sim.confere('respondido: nada esperando nós nesta conversa', :n2 = 0, :'n2');
select coalesce((select pior_resposta_min from public.v_atendimento_fatos where conversa_id = :'c'), -1) as p2 \gset
select sim.confere('a pior resposta mede a demora (~20 min)', :p2 >= 15, :'p2');

-- (c) o time assume e fala por último: o cliente calado nunca é "esperando nós"
select sim.como('backoffice');
select public.backoffice_momento(null, 'assumir', jsonb_build_object('conversa_id', :'c'));
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi! Sou o Ricardo, vou seguir com você. Consegue me passar o CEP?');
select sim.fila_rodar();
select sim.como('servico');
select coalesce((select caixa || ':' || ult_quem from public.v_atendimento_fatos where conversa_id = :'c'), '') as k3 \gset
select sim.confere('o time falou por último: não é esperando nós', :'k3' not like 'esperando_nos%' and :'k3' like '%:time', :'k3');
