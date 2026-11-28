-- id: X163
-- titulo: 0441 (pendência da Live 2.0, regra 20 item 5): a conferência diária acusa cliente esperando fora da fila da Live 2.0 — furo aberto = falha; furo fechado nas últimas 24 h ou conferência de cobertura parada há mais de 24 h = atenção; rodou e não achou = ok
-- tipo: atual

select sim._servico();
delete from public.live2_furos;
delete from public.live2_cobertura;

-- 1) a conferência de cobertura nunca rodou → atenção (zero furo sem rodada não prova nada)
select sim.como('backoffice');
select sim.confere('sem rodada da conferência de cobertura: atenção',
  (select i ->> 'nivel' = 'atencao' and (i ->> 'n')::int = 0 from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'live2_furos'),
  (select i::text from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'live2_furos'));

-- 2) rodou agora e não achou nada → ok
select sim._servico();
insert into public.live2_cobertura (parceiro_id, rodada_em, esperando, furos) values ('dharma', now(), 0, 0);
select sim.como('backoffice');
select sim.confere('rodou nas últimas 24 h e não achou furo: ok',
  (select i ->> 'nivel' = 'ok' and (i ->> 'n')::int = 0 from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'live2_furos'),
  (select i::text from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'live2_furos'));

-- 3) furo de 5 h atrás, já fechado → atenção
select sim._servico();
insert into public.live2_furos (conversa_id, nome, desde, visto_em, fechado_em)
values (gen_random_uuid(), 'Fulano X163', now() - interval '6 hours', now() - interval '5 hours', now() - interval '4 hours');
select sim.como('backoffice');
select sim.confere('furo fechado nas últimas 24 h: atenção, n = 0',
  (select i ->> 'nivel' = 'atencao' and (i ->> 'n')::int = 0 and i ->> 'texto' like '%Fulano X163%' from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'live2_furos'),
  (select i::text from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'live2_furos'));

-- 4) furo aberto agora → falha
select sim._servico();
insert into public.live2_furos (conversa_id, nome, desde, visto_em)
values (gen_random_uuid(), 'Beltrana X163', now() - interval '40 minutes', now() - interval '25 minutes');
select sim.como('backoffice');
select sim.confere('furo aberto: falha, n = 1, com o que fazer',
  (select i ->> 'nivel' = 'falha' and (i ->> 'n')::int = 1 and i ->> 'fazer' is not null from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'live2_furos'),
  (select i::text from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'live2_furos'));

-- 5) furo antigo (3 dias) e fechado não conta
select sim._servico();
delete from public.live2_furos;
insert into public.live2_furos (conversa_id, nome, desde, visto_em, fechado_em)
values (gen_random_uuid(), 'Antigo X163', now() - interval '3 days', now() - interval '3 days', now() - interval '3 days' + interval '20 minutes');
select sim.como('backoffice');
select sim.confere('furo de 3 dias atrás, fechado, não conta: ok',
  (select i ->> 'nivel' = 'ok' from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'live2_furos'),
  (select i::text from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'live2_furos'));
