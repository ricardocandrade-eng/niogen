-- id: X14
-- titulo: Cliente some depois de falar com o time (0274): em 24 h úteis a Mari faz a Retomada (a conversa já voltou para ela, 0227); ele responde e a Mari atende
-- tipo: atual
select sim.lead_novo('Rosa X14') as c \gset
select sim.mari_handoff(:'c', 'pedido_humano');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_conversa(:'c', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi, Rosa! Sou do time. Me passa o seu CEP?');
select sim.fila_rodar();
select sim.como('servico');
select sim.espera(:'c', '2 hours');
select sim.confere('o time falou por último, com dono', sim.cw_de(:'c') ->> 'agente' is not null, sim.cw_de(:'c')::text);
select sim.passa(:'c', '6 days');
select sim.tique();
select sim.confere('24 h úteis sem resposta ao time: a Retomada começou', (select retomada_origem = 'time_sem_resposta' and retomada_fim_em is null from public.mari_conversas where id = :'c'),
  (select row(retomada_desde, retomada_origem)::text from public.mari_conversas where id = :'c'));
select sim.confere('o dono foi avisado por nota no Chatwoot', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'retomada' and a.tipo = 'nota'), 'sem nota');
select sim.fila_rodar();
select sim.passa(:'c', '1 day');
select public._retomada_tick(sim.meio_dia());
select sim.fila_rodar();
select sim.confere('o D3 saiu', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.payload ->> 'template' = 'nio_retomada_lead_d3' and a.status = 'feita'), 'sem D3');
select sim.confere('a cadência do n8n não manda nada junto', not exists (select 1 from sim.cadencia(sim.meio_dia()) x where x like '%enviado'), 'n8n');
select sim.cliente_escreve(:'c', 'oi, desculpa a demora! meu cep é 36010000') as r \gset
select sim.fila_rodar();
select sim.confere('o cliente respondeu: a Mari atende', :'r' = 'respondeu', :'r');
select sim.confere('a Retomada fechou: respondeu', (select retomada_fim = 'respondeu' from public.mari_conversas where id = :'c'),
  (select coalesce(retomada_fim, 'aberta') from public.mari_conversas where id = :'c'));
