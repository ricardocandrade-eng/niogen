-- id: X107
-- titulo: 0384 (Ricardo, 24/11: "A linha que mostrava os dados coletados do cliente dentro da Ficha e das Conversas sumiu"): o time logado lê a v_mari_quadro e a v_mari_cadencia (a 0381 tinha tirado o EXECUTE de _retomada_variante)
-- tipo: atual
select sim.como('servico');
grant authenticated, anon, service_role to authenticator;
select sim.lead_novo('Ana X107') as c \gset
create temp table _x107 (o_que text, r text);
grant all on _x107 to authenticated;
create or replace function pg_temp.tenta(p_sql text) returns text language plpgsql as $$
declare n int;
begin
  execute p_sql into n; return 'ok ' || n;
exception when others then return sqlstate || ' ' || sqlerrm;
end $$;
select sim.como('backoffice');
set session authorization authenticator;
set role authenticated;
insert into _x107 values
  ('quadro', pg_temp.tenta(format($$select count(*)::int from public.v_mari_quadro where id = %L::uuid$$, :'c'))),
  ('itens', pg_temp.tenta(format($$select coalesce(jsonb_array_length(itens::jsonb), 0) from public.v_mari_quadro where id = %L::uuid$$, :'c'))),
  ('cadencia', pg_temp.tenta($$select count(*)::int from public.v_mari_cadencia$$));
reset role;
reset session authorization;
select sim.como('servico');
select sim.confere('o time logado lê a v_mari_quadro (linha dos dados coletados na ficha)', (select r from _x107 where o_que = 'quadro') = 'ok 1',
  (select r from _x107 where o_que = 'quadro'));
select sim.confere('e ela traz os itens coletados', (select r from _x107 where o_que = 'itens') ~ '^ok [1-9]',
  (select r from _x107 where o_que = 'itens'));
select sim.confere('o time logado lê a v_mari_cadencia', (select r from _x107 where o_que = 'cadencia') like 'ok %',
  (select r from _x107 where o_que = 'cadencia'));
