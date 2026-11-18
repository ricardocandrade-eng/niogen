-- id: X27
-- titulo: Porta (0290): a Saída que a Mari dá (handoff com motivo de saída) e o fim da cadência ("Sem contato") passam pela porta — mesmo destino de antes
-- tipo: atual
-- (1) a Mari passa adiante por falta de cobertura → Saída sem cobertura, pela porta
select sim.lead_novo('Gil X27') as c \gset
select sim.mari_fala(:'c', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.mari_handoff(:'c', 'recusa_compra');
select sim.fila_rodar();
select sim.confere('Mari: recusou → destino recusou', sim.foto(:'c') ->> 'destino' = 'recusou', sim.foto(:'c')::text);
select sim.confere('a porta anotou a Saída da Mari (origem mari_handoff)',
  exists (select 1 from public.porta_sombra s where s.conversa_id = :'c' and s.evento = 'funil:recusou' and s.origem = 'mari_handoff'));

-- (2) fim da cadência: 48 h depois do D15 → Saída sem resposta, pela porta
select sim.lead_novo('Bia X27') as c2 \gset
select sim.mari_fala(:'c2', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim._servico();
select public.mari_cadencia_registrar(:'c2', 'ENCERRAR', true);
select sim.fila_rodar();
select sim.confere('fim da cadência → destino sem resposta', sim.foto(:'c2') ->> 'destino' = 'sem_resposta', sim.foto(:'c2')::text);
select sim.confere('a porta anotou o fim da cadência (origem mari_cadencia)',
  exists (select 1 from public.porta_sombra s where s.conversa_id = :'c2' and s.evento = 'funil:sem_resposta' and s.origem = 'mari_cadencia'));

-- (3) handoff que não é Saída (pediu humano): o destino não muda
select sim.lead_novo('Davi X27') as c3 \gset
select sim.mari_fala(:'c3', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.mari_handoff(:'c3', 'pedido_humano');
select sim.fila_rodar();
select sim.confere('pediu humano: segue em andamento', sim.foto(:'c3') ->> 'destino' = 'em_andamento', sim.foto(:'c3')::text);
