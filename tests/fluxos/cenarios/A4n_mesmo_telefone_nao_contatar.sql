-- id: A4n
-- titulo: Quem pediu para parar abre conversa nova: não reabre e a Mari não responde
-- tipo: atual
select sim.lead_novo('Bel A4n') as c \gset
select sim.cliente_escreve(:'c', 'PARAR');
select sim.fila_rodar();
select sim.espera(:'c', '1 day');
select sim.lead_novo('Bel A4n', 'oi', sim.tel(:'c')) as c2 \gset
select sim.fila_rodar();
select sim.confere('a Mari não respondeu na conversa nova',
  (select count(*) from sim.envios where conversa = :'c2' and por = 'mari') = 1,
  (select count(*) || ' falas da Mari (1 é a abertura da primeira conversa)' from sim.envios where conversa = :'c2' and por = 'mari'));
select sim.confere('continua Não contatar', (sim.foto(:'c2') ->> 'nao_contatar')::boolean, sim.foto(:'c2')::text);
select sim.confere('a etiqueta nao-contatar está na conversa nova', (sim.cw_de(:'c2') -> 'etiquetas') ? 'nao-contatar', sim.cw_de(:'c2')::text);
select sim.passa(:'c2', '2 days');
select count(*) as n from sim.cadencia(sim.meio_dia()) x where x like '%enviado' \gset
select sim.confere('a cadência não manda nada', :n = 0, 'envios: ' || :n);
