-- id: H6
-- titulo: Toque da cadência só sai no horário do contrato (0304: 9h–21h todo dia) — nunca de madrugada nem às 6h30
-- tipo: atual
select sim.lead_novo('Ivo H6') as c \gset
select sim.passa(:'c', now() - (sim.hora('02:00') - interval '3 days'));
select count(*) as n from sim.cadencia(sim.hora('03:00')) x where x like '%enviado' \gset
select sim.confere('o toque D3 (72 h) vence às 2h: às 3h não sai nada', :n = 0, 'envios às 3h: ' || :n);
select count(*) as m0 from sim.cadencia(sim.hora('06:30')) x where x like '%enviado' \gset
select sim.confere('às 6h30 ainda não sai (0304: abre às 9h)', :m0 = 0, 'envios às 6h30: ' || :m0);
select count(*) as m from sim.cadencia(sim.hora('09:30')) x where x like '%enviado' \gset
select sim.confere('às 9h30 o toque sai', :m >= 1, 'envios às 9h30: ' || :m);
