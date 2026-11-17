-- id: X9
-- titulo: Os botões da tela vêm da porta: porta_botoes concorda com a tabela em cada situação, esconde o recusado com a frase e respeita o "só admin" (0269)
-- tipo: atual
select sim.lead_com_venda('Carla X9') as c \gset
select sim.como('backoffice');

-- em andamento: tudo o que porta_botoes diz bate com porta_prever, evento por evento
select public.porta_botoes(:'c', sim.venda(:'c')) as b \gset
select sim.confere('porta_botoes devolve a situação do lead', (:'b'::jsonb -> 'situacao' ->> 'codigo') is not null, :'b'::jsonb ->> 'situacao');
select sim.confere('R13: em andamento, cada botão concorda com a tabela',
  not exists (select 1 from jsonb_each(:'b'::jsonb -> 'eventos') e(k, v)
               cross join lateral public.porta_prever(:'b'::jsonb -> 'situacao' ->> 'codigo', e.k) p
              where (v ->> 'aceito')::boolean is distinct from p.aceito
                 or ((v ->> 'ok')::boolean and p.aceito is false)),
  (select string_agg(k, ', ') from jsonb_each(:'b'::jsonb -> 'eventos') e(k, v)
     cross join lateral public.porta_prever(:'b'::jsonb -> 'situacao' ->> 'codigo', e.k) p where (v ->> 'aceito')::boolean is distinct from p.aceito));
select sim.confere('em andamento, Assumir aparece e diz o que vai acontecer',
  (:'b'::jsonb #>> '{eventos,momento:assumir,ok}')::boolean and coalesce(:'b'::jsonb #>> '{eventos,momento:assumir,efeito}', '') like '%Mari para de responder%',
  :'b'::jsonb #>> '{eventos,momento:assumir}');
select sim.confere('em andamento, Reabrir não aparece e diz por quê',
  not (:'b'::jsonb #>> '{eventos,reabrir,ok}')::boolean and coalesce(:'b'::jsonb #>> '{eventos,reabrir,frase}', '') <> '',
  :'b'::jsonb #>> '{eventos,reabrir}');
select sim.confere('robôs e Mari não viram botão', not (:'b'::jsonb -> 'eventos' ? 'cliente_escreveu') and not exists (
  select 1 from jsonb_object_keys(:'b'::jsonb -> 'eventos') k where split_part(k, ':', 1) in ('nio', 'funil', 'prazo', 'mari_passou')), null);

-- em Saída: a tela esconde Assumir com a MESMA frase que a porta usa para recusar
select public.lead_sair(:'c', sim.venda(:'c'), 'recusou', 'preco');
select sim.fila_rodar();
select public.porta_botoes(:'c', sim.venda(:'c')) as b2 \gset
select coalesce(sim.recusa(format($q$select public.backoffice_momento(%L, 'assumir')$q$, sim.venda(:'c'))), '') as rec \gset
select sim.confere('em Saída, Assumir some da tela', not (:'b2'::jsonb #>> '{eventos,momento:assumir,ok}')::boolean, :'b2'::jsonb #>> '{eventos,momento:assumir}');
select sim.confere('a frase da tela é a frase da recusa', :'rec' like '%' || (:'b2'::jsonb #>> '{eventos,momento:assumir,frase}') || '%',
  :'rec' || ' | ' || coalesce(:'b2'::jsonb #>> '{eventos,momento:assumir,frase}', '(sem frase)'));
select sim.confere('em Saída, Reabrir aparece', (:'b2'::jsonb #>> '{eventos,reabrir,ok}')::boolean, :'b2'::jsonb #>> '{eventos,reabrir}');

-- Saída definitiva: Reabrir só aparece para o admin
select public.lead_sair(:'c', sim.venda(:'c'), 'credito_negado', null);
select sim.fila_rodar();
select public.porta_botoes(:'c', sim.venda(:'c')) as b3 \gset
select sim.confere('Saída definitiva: o backoffice não vê Reabrir', not (:'b3'::jsonb #>> '{eventos,reabrir,ok}')::boolean
  and (:'b3'::jsonb #>> '{eventos,reabrir,exige}') = 'admin', :'b3'::jsonb #>> '{eventos,reabrir}');
select sim.como('admin');
select public.porta_botoes(:'c', sim.venda(:'c')) as b4 \gset
select sim.confere('Saída definitiva: o admin vê Reabrir', (:'b4'::jsonb #>> '{eventos,reabrir,ok}')::boolean, :'b4'::jsonb #>> '{eventos,reabrir}');
