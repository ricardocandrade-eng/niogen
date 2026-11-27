-- id: X148
-- titulo: Caso L-434 (0425, Ricardo 26/11: "sem querer eu marquei a mão como viável e agora não consigo corrigir mais"): o robô do portal respondeu sem viabilidade, o viável foi gravado pela ficha por cima e não havia volta. Desfazer volta ao que o robô respondeu; sem resposta do robô volta a não consultado; viável do robô não se desfaz
-- tipo: atual

-- 1) o robô responde "sem viabilidade" (DFV sem) e a ficha grava viável por cima, por engano
select sim.lead_pronto('Mauro X148') as a \gset
select sim._servico();
select public.mari_viab_gravar(:'a', jsonb_build_object('resultado', 'sem_viabilidade',
  'endereco', jsonb_build_object('resolvido', 'Rua Simulada, 380', 'viabilidade', 'Indisponível · Sem viabilidade técnica')),
  jsonb_build_object('match', 'nao_encontrado', 'total_fachadas_no_cep', 0, 'fonte', 'api')) as r \gset
select cobertura_decisao as antes from public.mari_conversas where id = :'a' \gset
select sim.confere('o robô decidiu que não é viável', :'antes' <> 'viavel', :'antes');
select sim.como('backoffice');
select public.lead_registrar_consulta(:'a', 'viabilidade', 'viavel');
select sim.confere('o engano: viável gravado pela ficha por cima do "não" do robô',
  (select cobertura_decisao = 'viavel' and cobertura_detalhe ->> 'registrado_na_ficha' = 'true' from public.mari_conversas where id = :'a'), null);

-- 2) desfazer volta ao que o robô respondeu
select public.lead_registrar_consulta(:'a', 'viabilidade', 'desfazer') ->> 'resumo' as resumo \gset
select sim.confere('desfazer: a decisão volta à do robô e o registro manual some',
  (select cobertura_decisao = :'antes' and nio_viab_resultado = 'sem_viabilidade' and cobertura_detalhe ->> 'portal' = 'sem_viabilidade'
          and cobertura_detalhe ? 'registrado_na_ficha' = false and cobertura_detalhe ->> 'portal_texto' like 'Indispon%'
     from public.mari_conversas where id = :'a'),
  (select cobertura_decisao || ' · ' || coalesce(nio_viab_resultado, '—') || ' · ' || cobertura_detalhe::text from public.mari_conversas where id = :'a'));
select sim.confere('desfazer: o viável falso sai da etapa do funil',
  (select funil_etapa is distinct from 'viavel' from public.mari_conversas where id = :'a'),
  (select coalesce(funil_etapa, '—') from public.mari_conversas where id = :'a'));
select sim.confere('desfazer: fica registrado quem desfez',
  exists (select 1 from public.operador_consultas where conversa_id = :'a' and origem = 'tela' and resultado = 'desfeito'), :'resumo');

-- 3) sem viável da ficha, não há o que desfazer
create temp table _x148 (caso text, ok boolean, msg text);
create temp table _x148v as select :'a'::uuid as a;
do $$
begin
  begin
    perform public.lead_registrar_consulta((select a from _x148v), 'viabilidade', 'desfazer');
    insert into _x148 values ('nada', false, 'desfez de novo');
  exception when others then insert into _x148 values ('nada', sqlerrm like '%para desfazer%', sqlerrm);
  end;
end $$;
select sim.confere('sem viável da ficha: recusa', (select ok from _x148 where caso = 'nada'), (select msg from _x148 where caso = 'nada'));

-- 4) sem resposta do robô: o viável da ficha desfeito volta a "não consultado"
select sim.lead_pronto('Nina X148') as b \gset
select sim._servico();
update public.mari_conversas set nio_viab_resultado = null, nio_viab_em = null, cobertura_decisao = null, cobertura_em = null, cobertura_detalhe = null where id = :'b';
delete from public.operador_consultas where conversa_id = :'b';
select sim.como('backoffice');
select public.lead_registrar_consulta(:'b', 'viabilidade', 'viavel');
select public.lead_registrar_consulta(:'b', 'viabilidade', 'desfazer');
select sim.confere('sem robô: volta a não consultado',
  (select cobertura_decisao is null and nio_viab_resultado is null and nio_viab_em is null from public.mari_conversas where id = :'b'),
  (select coalesce(cobertura_decisao, '—') || ' · ' || coalesce(nio_viab_resultado, '—') from public.mari_conversas where id = :'b'));

-- 5) o robô também disse viável: não se desfaz por aqui (sem viabilidade de verdade é Saída › Fachada não atendida)
select sim.lead_pronto('Olga X148') as d \gset
select sim._servico();
select public.mari_viab_gravar(:'d', jsonb_build_object('resultado', 'viavel', 'velocidade', '1GB')) as r2 \gset
select sim.como('backoffice');
select public.lead_registrar_consulta(:'d', 'viabilidade', 'viavel');
create temp table _x148d as select :'d'::uuid as d;
do $$
begin
  begin
    perform public.lead_registrar_consulta((select d from _x148d), 'viabilidade', 'desfazer');
    insert into _x148 values ('robo', false, 'desfez o viável do robô');
  exception when others then insert into _x148 values ('robo', sqlerrm like '%também respondeu%', sqlerrm);
  end;
end $$;
select sim.confere('viável do robô: recusa e manda para a Saída', (select ok from _x148 where caso = 'robo'), (select msg from _x148 where caso = 'robo'));
select sim.confere('viável do robô: continua viável', (select cobertura_decisao = 'viavel' from public.mari_conversas where id = :'d'), null);
