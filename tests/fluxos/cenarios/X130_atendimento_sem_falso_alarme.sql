-- id: X130
-- titulo: 0400 (25/11, Ricardo: "Essa leitura de que há sempre um problema no atendimento, quando na verdade não"): "tá bom" do cliente depois de despedida nossa não é esperando nós; "ok" a uma pergunta nossa continua sendo; retorno combinado aberto tira da conta; o resumo só conta espera acima de 15 min
-- tipo: atual
-- Caso: Poços de Caldas, 24/11 — "A gente vai se falando" → "Ta bom", retorno marcado para 25/11 16h; o agente leu "esperando nós" por 17 h.
select sim.lead_novo('Ana X130') as c \gset
select sim.como('backoffice');
select public.backoffice_conversa(:'c', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Pedido feito! Fica atenta no e-mail. A gente vai se falando');
select sim.fila_rodar();

-- (a) o cliente encerra com cortesia: não é esperando nós
select sim.como('servico');
select sim.cliente_escreve(:'c', 'Ta bom', false);
select sim.espera(:'c', '40 minutes');
select sim.como('servico');
select coalesce((select caixa || ':' || cliente_encerrou from public.v_atendimento_fatos where conversa_id = :'c'), '') as k1 \gset
select sim.confere('"Ta bom" depois da despedida: não é esperando nós, cliente encerrou', :'k1' not like 'esperando_nos%' and :'k1' like '%:true', :'k1');
select coalesce((select (x ->> 'n')::int from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'esperando_nos'
                 and x::text like '%Ana X130%'), 0) as n1 \gset
select sim.confere('o Conferir não aponta a cortesia', :n1 = 0, :'n1');

-- (b) o cliente pergunta de novo: volta a ser esperando nós
select sim.cliente_escreve(:'c', 'e quando instala?', false);
select sim.espera(:'c', '20 minutes');
select sim.como('servico');
select coalesce((select caixa || ':' || cliente_encerrou from public.v_atendimento_fatos where conversa_id = :'c'), '') as k2 \gset
select sim.confere('pergunta do cliente sem resposta: esperando nós', :'k2' = 'esperando_nos:false', :'k2');
select coalesce((select (public.atendimento_leitura(now() - interval '1 day') -> 'esperando_nos')::int), -1) as r2 \gset
select sim.confere('o resumo conta a espera acima de 15 min', :r2 >= 1, :'r2');

-- (c) nossa fala com pergunta + "ok" do cliente: é resposta, continua esperando nós
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Posso confirmar o seu e-mail pra Nio mandar a biometria?');
select sim.fila_rodar();
select sim.como('servico');
select sim.cliente_escreve(:'c', 'ok', false);
select sim.espera(:'c', '5 minutes');
select sim.como('servico');
select coalesce((select caixa || ':' || cliente_encerrou from public.v_atendimento_fatos where conversa_id = :'c'), '') as k3 \gset
select sim.confere('"ok" a uma pergunta nossa: esperando nós (é resposta, não despedida)', :'k3' = 'esperando_nos:false', :'k3');
select coalesce((select (public.atendimento_leitura(now() - interval '1 day') ->> 'esperando_nos_ate_15min')::int), -1) as r3 \gset
select sim.confere('com 5 min ela entra em "até 15 min", não na lista de falhas', :r3 >= 1, :'r3');
select coalesce((select count(*) from jsonb_array_elements(public.atendimento_leitura(now() - interval '1 day') -> 'falhas') x
                  where x ->> 'lead_id' = (select lead_id::text from public.v_atendimento_fatos where conversa_id = :'c')), -1) as f3 \gset
select sim.confere('5 min de espera não é falha', :f3 = 0, :'f3');

-- (d) o time marca o retorno combinado: sai da conta
select sim.como('backoffice');
select public.retorno_marcar(:'c', now() + interval '1 day', 'cliente pediu para chamar amanhã') ->> 'quem' as q4 \gset
select sim.fila_rodar();
select sim.como('servico');
select coalesce((select caixa || ':' || retorno_aberto from public.v_atendimento_fatos where conversa_id = :'c'), '') as k4 \gset
select sim.confere('retorno combinado aberto: não é esperando nós', :'k4' not like 'esperando_nos%' and :'k4' like '%:true', :'k4');

-- (e) a função de cortesia: casos de borda
select sim.confere('cortesias reconhecidas',
  public._fala_de_cortesia('Ta bom') and public._fala_de_cortesia('Ok, obrigado!') and public._fala_de_cortesia('👍')
  and public._fala_de_cortesia('valeu') and public._fala_de_cortesia('Tá bom, fico no aguardo'), 'cortesia');
select sim.confere('o que pede resposta não é cortesia',
  not public._fala_de_cortesia('Sim') and not public._fala_de_cortesia('ok?') and not public._fala_de_cortesia('bom dia')
  and not public._fala_de_cortesia('ok mas e o preço') and not public._fala_de_cortesia(''), 'nao cortesia');
