-- id: X97
-- titulo: Avisos da tela Canais (Ricardo, 23/11 19h12): "marcar como tratado" esconde o aviso por 48 h; passado o prazo ele volta se o indicador não melhorou (e volta se piorar de novo); aviso que sumiu e voltou começa sem o tratamento antigo; só admin/backoffice tratam; a conferência fecha
-- tipo: atual
-- premissa (24/11, portão da 0378/0379): a cópia do banco vem do backup do dia e já traz avisos reais da tela Canais — o cenário
-- começa sem eles (o banco do cenário é descartável)
delete from public.canal_aviso_tratado; delete from public.canal_aviso;

select sim.como('admin');
select public.canal_avisos_sincronizar('google_ads', '[{"chave":"google:classificacao","titulo":"perde buscas pela classificação","valor":0.70}]') as s1 \gset
select sim.confere('aviso novo abre com data e aparece',
  (:'s1'::jsonb #>> '{avisos,google:classificacao,aberto_em}') is not null
  and (:'s1'::jsonb #>> '{avisos,google:classificacao,escondido}')::boolean = false, :'s1');

-- só admin/backoffice tratam
select sim.como('vendedor');
select sim.confere('vendedor não marca aviso como tratado',
  sim.recusa($q$ select public.canal_aviso_tratar('google_ads', 'google:classificacao', 'x') $q$) is not null, null);
select sim.como('admin');
select sim.confere('aviso que não está aberto não se trata',
  sim.recusa($q$ select public.canal_aviso_tratar('google_ads', 'google:nao_existe', null) $q$) like '%não está aberto%', null);

select public.canal_aviso_tratar('google_ads', 'google:classificacao', 'teto de CPC 3 → 8') as t \gset
select sim.confere('tratado fica escondido', (:'t'::jsonb ->> 'escondido')::boolean, :'t');

-- passaram 49 h
update public.canal_aviso_tratado set tratado_em = now() - interval '49 hours' where aviso_chave = 'google:classificacao';
select public.canal_avisos_sincronizar('google_ads', '[{"chave":"google:classificacao","valor":0.70}]') as s2 \gset
select sim.confere('49 h depois, sem melhora, o aviso volta',
  (:'s2'::jsonb #>> '{avisos,google:classificacao,escondido}')::boolean = false, :'s2');
select public.canal_avisos_sincronizar('google_ads', '[{"chave":"google:classificacao","valor":0.50}]') as s3 \gset
select sim.confere('49 h depois, melhorou: segue escondido',
  (:'s3'::jsonb #>> '{avisos,google:classificacao,escondido}')::boolean = true, :'s3');
select public.canal_avisos_sincronizar('google_ads', '[{"chave":"google:classificacao","valor":0.80}]') as s4 \gset
select sim.confere('piorou de novo: volta',
  (:'s4'::jsonb #>> '{avisos,google:classificacao,escondido}')::boolean = false, :'s4');

-- some e volta = episódio novo, sem o tratamento antigo
select public.canal_aviso_tratar('google_ads', 'google:classificacao', null);
select public.canal_avisos_sincronizar('google_ads', '[]');
select sim.confere('aviso que sumiu fecha o episódio',
  not exists (select 1 from public.canal_aviso where aviso_chave = 'google:classificacao' and fechado_em is null), null);
select public.canal_avisos_sincronizar('google_ads', '[{"chave":"google:classificacao","valor":0.70}]') as s5 \gset
select sim.confere('voltou: episódio novo, aparece (o tratamento antigo não vale)',
  (:'s5'::jsonb #>> '{avisos,google:classificacao,escondido}')::boolean = false
  and (select count(*) from public.canal_aviso where aviso_chave = 'google:classificacao') = 2, :'s5');

-- a conferência fecha
select sim.confere('conferência: avisos da tela Canais em ordem',
  (select x->>'nivel' from jsonb_array_elements(public.conferencia_itens()) x where x->>'codigo' = 'canal_avisos') = 'ok',
  (select x::text from jsonb_array_elements(public.conferencia_itens()) x where x->>'codigo' = 'canal_avisos'));
select sim.confere('limites do aviso de clique → conversa estão em config (não fixos no código)',
  (select count(*) from public.config_meta_ads_regras where chave in ('aviso_tratado_horas', 'clique_conversa_min_cliques', 'clique_conversa_taxa_min')) = 3, null);
