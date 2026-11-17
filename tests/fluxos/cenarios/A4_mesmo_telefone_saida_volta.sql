-- id: A4
-- titulo: Mesmo telefone abre conversa nova tendo outra em Saída: é o mesmo lead e reabre
-- tipo: atual
select sim.lead_novo('Ana A4') as c \gset
select sim.como('backoffice');
select public.lead_sair(:'c', null, 'recusou', 'preco');
select sim.fila_rodar();
select sim.como('servico');
select sim.espera(:'c', '1 day');
select sim.lead_novo('Ana A4', 'Oi, voltei. Ainda tem aquele plano?', sim.tel(:'c')) as c2 \gset
select sim.fila_rodar();
select sim.confere('é o mesmo lead (uma conversa só no NIOGEN)', :'c2' = :'c', :'c2');
select sim.confere('reabriu: em andamento', sim.lead_de(:'c') ->> 'destino' = 'em_andamento', sim.lead_de(:'c')::text);
select sim.confere('a Mari respondeu na conversa nova',
  (select count(*) from sim.envios where conversa = :'c' and por = 'mari') = 2,
  (select count(*) || ' falas da Mari' from sim.envios where conversa = :'c' and por = 'mari'));
