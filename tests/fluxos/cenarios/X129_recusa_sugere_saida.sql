-- id: X129
-- titulo: 0399 (caso L-287; Ricardo, 25/11: "Faz a sugestão de Saída na hora, na própria conversa"): lead_recusa diz na hora que a última fala do cliente é uma recusa curta em conversa com o time — antes e depois de o time responder; frase longa não conta; conversa com a Mari não sugere; depois da Saída não sugere mais; fora do backoffice não devolve nada
-- tipo: atual
select sim.lead_novo('Lia X129') as c \gset
select sim.como('backoffice');
select public.backoffice_conversa(:'c', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi, Lia! Vamos seguir com o pedido?');
select sim.fila_rodar();
select sim.como('backoffice');
select sim.confere('sem recusa, nada a sugerir', not (public.lead_recusa(:'c') ->> 'recusa')::boolean, public.lead_recusa(:'c')::text);

-- 1) o cliente recusa: a sugestão aparece na hora, antes de o time responder
select sim.como('servico');
select sim.cliente_escreve(:'c', 'Não obrigada', false);
select sim.fila_rodar();
select sim.como('backoffice');
select public.lead_recusa(:'c')::text as r1 \gset
select sim.confere('recusa detectada na hora, com a fala do cliente',
  ((:'r1')::jsonb ->> 'recusa')::boolean and (:'r1')::jsonb ->> 'fala' = 'Não obrigada' and not ((:'r1')::jsonb ->> 'respondida')::boolean, :'r1');
select sim.confere('conversa sem venda: sem pedido aberto no portal', (:'r1')::jsonb ->> 'venda_id' is null and not ((:'r1')::jsonb ->> 'pedido_aberto')::boolean, :'r1');

-- 2) o time se despede: continua sugerindo, agora como "respondida"
select public.backoffice_responder(:'c', 'Que pena! Se mudar de ideia, pode contar comigo.');
select sim.fila_rodar();
select sim.como('backoffice');
select public.lead_recusa(:'c')::text as r2 \gset
select sim.confere('depois da resposta do time a sugestão continua', ((:'r2')::jsonb ->> 'recusa')::boolean and ((:'r2')::jsonb ->> 'respondida')::boolean, :'r2');

-- 3) frase longa com "não quero" não é tratada como recusa
select sim.como('servico');
select sim.cliente_escreve(:'c', 'Não quero o Essencial, prefiro o Fibra de 600 mega porque uso muito a internet em casa, pode ser?', false);
select sim.fila_rodar();
select sim.como('backoffice');
select sim.confere('fala longa não vira recusa', not (public.lead_recusa(:'c') ->> 'recusa')::boolean, public.lead_recusa(:'c')::text);

-- 4) recusa de novo e a Saída é registrada pela porta: a sugestão some
select sim.como('servico');
select sim.cliente_escreve(:'c', 'não quero mais', false);
select sim.fila_rodar();
select sim.como('backoffice');
select sim.confere('nova recusa curta volta a sugerir', (public.lead_recusa(:'c') ->> 'recusa')::boolean, public.lead_recusa(:'c')::text);
select public.lead_sair(p_conversa := :'c', p_venda := null, p_motivo := 'recusou', p_sub := 'desistiu', p_volta := null, p_obs := null, p_cancelou_portal := null);
select sim.fila_rodar();
select sim.como('backoffice');
select sim.confere('com a Saída registrada, nada mais a sugerir', not (public.lead_recusa(:'c') ->> 'recusa')::boolean, public.lead_recusa(:'c')::text);

-- 5) conversa que a Mari atende (sem dono): a tela não sugere Saída
select sim.como('servico');
select sim.lead_novo('Mel X129') as d \gset
select sim.cliente_escreve(:'d', 'Não quero', false);
select sim.fila_rodar();
select sim.como('backoffice');
select sim.confere('conversa com a Mari não sugere Saída', not (public.lead_recusa(:'d') ->> 'recusa')::boolean, public.lead_recusa(:'d')::text);

-- 6) uma lista só, e só para o backoffice
select sim.confere('a lista de frases existe e é a mesma para a fila e a conversa', length(public._recusa_regex()) > 20, 'vazia');
select sim.como('servico');
select sim.confere('fora do backoffice/admin não devolve nada', public.lead_recusa(:'c') is null, 'devolveu');
