-- id: X123
-- titulo: 0392 (Live 2.0, passo 3): a medição dos 7 dias — conta por dia as respostas de pessoa no horário e as esperas longas, os furos e as aberturas de cada tela; tela_abriu soma uma abertura por pessoa e dia e ignora tela desconhecida; fora do backoffice não devolve nada
-- tipo: atual
select sim.como('backoffice');
select public.tela_abriu('live2');
select public.tela_abriu('live2');
select public.tela_abriu('conversas');
select public.tela_abriu('qualquer_outra');
select sim.confere('duas aberturas da Live 2.0 viram n = 2 numa linha só',
  (select n from public.tela_aberturas where tela = 'live2' and por = auth.uid() and dia = (now() at time zone 'America/Sao_Paulo')::date) = 2,
  (select string_agg(tela || '=' || n, ', ') from public.tela_aberturas));
select sim.confere('tela desconhecida não é contada', not exists (select 1 from public.tela_aberturas where tela = 'qualquer_outra'), 'contou');
select public.live2_medicao(7)::text as m \gset
select sim.confere('a medição traz a base, o total, os 7 dias e o reforço',
  (:'m')::jsonb ?& array['base', 'total', 'dias', 'reforco'] and jsonb_array_length((:'m')::jsonb -> 'dias') = 7, left(:'m', 300));
select sim.confere('o dia de hoje mostra as aberturas de tela',
  exists (select 1 from jsonb_array_elements((:'m')::jsonb -> 'dias') d
           where d ->> 'dia' = ((now() at time zone 'America/Sao_Paulo')::date)::text and (d ->> 'abriu_live2')::int = 2 and (d ->> 'abriu_conversas')::int = 1),
  (:'m')::jsonb -> 'dias' ->> 6);
select sim.confere('as esperas longas nunca passam do total de respostas',
  not exists (select 1 from jsonb_array_elements((:'m')::jsonb -> 'dias') d where (d ->> 'acima_30')::int > (d ->> 'respostas')::int
                 or (d ->> 'acima_2h')::int > (d ->> 'acima_30')::int), 'conta errada');
select sim.como('servico');
select public.tela_abriu('live2');
select sim.confere('fora do backoffice/admin: medição null e abertura não contada',
  public.live2_medicao(7) is null and (select coalesce(sum(n), 0) from public.tela_aberturas where tela = 'live2') = 2, 'contou ou devolveu');
