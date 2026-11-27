-- id: X157
-- titulo: 0435 (Ricardo, 27/11: "Pode seguir com o alarme de reinício"): o Postgres reiniciou 8 vezes numa tarde e ninguém soube pelo sistema — cada início do banco fica anotado (banco_reinicio_registrar, a cada 2 min) e a conferência diária acusa: nenhum nas últimas 24 h = ok, um = atenção, dois ou mais = falha, com os horários; reinício antigo não conta
-- tipo: atual

select sim._servico();
-- parte de uma tabela limpa (a cópia traz os reinícios de 27/11 da própria migration)
delete from public.banco_reinicios;

-- 1) a rotina anota o início de agora, uma vez só
select public.banco_reinicio_registrar() is not null as primeira \gset
select public.banco_reinicio_registrar() is null as segunda \gset
select sim.confere('a rotina anota o início atual do Postgres na primeira vez e não repete',
  :'primeira'::boolean and :'segunda'::boolean and (select count(*) = 1 from public.banco_reinicios),
  (select count(*)::text from public.banco_reinicios));
select sim.confere('a linha anotada é a hora em que o Postgres subiu',
  (select subiu_em = date_trunc('second', pg_postmaster_start_time()) and origem = 'rotina' from public.banco_reinicios),
  (select row(subiu_em, origem)::text from public.banco_reinicios));

-- 2) a conferência: sem reinício nas últimas 24 h → ok
delete from public.banco_reinicios;
insert into public.banco_reinicios (subiu_em) values (now() - interval '3 days');
select sim.como('backoffice');
select sim.confere('reinício de 3 dias atrás não conta: item ok',
  (select i ->> 'nivel' = 'ok' and (i ->> 'n')::int = 0 from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'banco_reinicio'),
  (select i::text from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'banco_reinicio'));

-- 3) um reinício nas últimas 24 h → atenção
select sim._servico();
insert into public.banco_reinicios (subiu_em) values (now() - interval '5 hours');
select sim.como('backoffice');
select sim.confere('um reinício nas últimas 24 h: atenção',
  (select i ->> 'nivel' = 'atencao' and (i ->> 'n')::int = 1 and i ->> 'fazer' is not null from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'banco_reinicio'),
  (select i::text from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'banco_reinicio'));

-- 4) em série → falha, com os horários e o que fazer
select sim._servico();
insert into public.banco_reinicios (subiu_em) values (now() - interval '4 hours'), (now() - interval '3 hours 50 minutes');
select sim.como('backoffice');
select sim.confere('três reinícios nas últimas 24 h: falha, com os horários e a memória como causa provável',
  (select i ->> 'nivel' = 'falha' and (i ->> 'n')::int = 3 and i ->> 'texto' ~ '3 vez' and i ->> 'texto' ~ '\d\d/\d\d \d\d:\d\d, \d\d/\d\d' and i ->> 'fazer' ~* 'mem[óo]ria'
     from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'banco_reinicio'),
  (select i::text from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'banco_reinicio'));

-- 5) a tabela só é gravada pela função: quem está logado não lê nem grava direto
select sim.confere('a tabela não é lida direto por usuário logado (só pela conferência)',
  not has_table_privilege('authenticated', 'public.banco_reinicios', 'select')
  and not has_table_privilege('authenticated', 'public.banco_reinicios', 'insert')
  and not has_function_privilege('authenticated', 'public.banco_reinicio_registrar()', 'execute'),
  'authenticated tem acesso');
