-- id: X80
-- titulo: 0354 (regra 19, 22/11): a jornada da Live não roda mais a cadência da Mari — a v_mari_quadro_jornada é a v_mari_quadro coluna a coluna (fora as 7 da cadência), e a v_jornada não depende mais da v_mari_cadencia
-- tipo: atual
select sim.como('servico');
-- alguns leads em situações diferentes: com a Mari, com o time esperando, cliente que escreveu ao time
select sim.lead_novo('Ana X80') as a \gset
select sim.mari_fala(:'a', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.lead_novo('Bia X80') as b \gset
select sim.como('backoffice');
select public.backoffice_conversa(:'b', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'b', 'Oi, Bia! Me passa o seu CEP?');
select sim.fila_rodar();
select sim.como('servico');
select sim.lead_novo('Cris X80') as c \gset
select sim.como('backoffice');
select public.backoffice_conversa(:'c', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('servico');
select sim.cliente_escreve(:'c', 'oi, pode falar?', false) as r \gset
select sim.fila_rodar();
select sim.como('servico');

select sim.confere('a v_jornada não depende mais da cadência (v_mari_cadencia)',
  not exists (
    with recursive dep(o) as (
      select 'public.v_jornada'::regclass::oid
      union
      select distinct d2.refobjid from dep join pg_rewrite r on r.ev_class = dep.o
        join pg_depend d2 on d2.objid = r.oid and d2.refobjid <> dep.o
        join pg_class c on c.oid = d2.refobjid and c.relkind in ('v', 'm'))
    select 1 from dep where o = 'public.v_mari_cadencia'::regclass::oid),
  'a v_jornada ainda chega na v_mari_cadencia');

select count(*) as dif from (
  (select to_jsonb(q) - array['proximo_passo','proximo_em','pode_enviar','bloqueio','contatos_hoje','contatos_mes','proximo_toque_em'] from public.v_mari_quadro q
   except
   select to_jsonb(q) - array['proximo_passo','proximo_em','pode_enviar','bloqueio','contatos_hoje','contatos_mes','proximo_toque_em'] from public.v_mari_quadro_jornada q)
  union all
  (select to_jsonb(q) - array['proximo_passo','proximo_em','pode_enviar','bloqueio','contatos_hoje','contatos_mes','proximo_toque_em'] from public.v_mari_quadro_jornada q
   except
   select to_jsonb(q) - array['proximo_passo','proximo_em','pode_enviar','bloqueio','contatos_hoje','contatos_mes','proximo_toque_em'] from public.v_mari_quadro q)) x \gset
select sim.confere('a v_mari_quadro_jornada é a v_mari_quadro (fora a cadência)', :dif = 0, :'dif' || ' linhas diferentes');
select sim.confere('as colunas das duas views são as mesmas, na mesma ordem e com o mesmo tipo',
  (select string_agg(attname || ':' || format_type(atttypid, atttypmod), ',' order by attnum) from pg_attribute
    where attrelid = 'public.v_mari_quadro'::regclass and attnum > 0 and not attisdropped)
  = (select string_agg(attname || ':' || format_type(atttypid, atttypmod), ',' order by attnum) from pg_attribute
    where attrelid = 'public.v_mari_quadro_jornada'::regclass and attnum > 0 and not attisdropped), 'colunas diferentes');
select coalesce((select o_que_fazer from public.v_jornada where conversa_id = :'c'), '') as t \gset
select sim.confere('a jornada segue dizendo o que fazer (cliente escreveu ao time)', :'t' <> '', :'t');
