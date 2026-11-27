-- id: X137
-- titulo: 0408 (Ricardo 25/11, "Sim, põe a trava"): o retrato do agente de tráfego diz o dono de cada campanha (dharma · agencia · sem_dono), por anúncio, por conjunto e na lista campanhas_dono — para ele só mexer nas da Dharma; os números não mudam
-- tipo: atual
select sim.como('servico');
-- 27/11: o cenário monta o próprio estado — na produção já há campanha liberada à agência (vem no backup); aqui toda campanha que
-- já existe começa com a Dharma, e só a que o cenário cria muda de dono.
insert into public.meta_ads_campanhas_dono (campanha_id, dono, classificada_em)
select distinct x.campanha_id, 'dharma', now()
  from (select campanha_id from public.meta_ads_diario union select campanha_id from public.meta_ads_anuncios) x where x.campanha_id is not null
on conflict (campanha_id) do update set dono = 'dharma';
update public.meta_ads_campanhas_dono set dono = 'dharma' where dono is distinct from 'dharma';
select public.agente_trafego_retrato(14) as antes \gset

-- a agência sobe uma campanha (entra sem dono); depois o admin a libera
insert into public.meta_ads_anuncios (ad_id, ad_nome, adset_id, adset_nome, campanha_id, campanha_nome, status_efetivo, atualizado_em)
values ('adX137', 'AG_anuncio_X137', 'asX137', 'AG_conjunto_X137', 'cX137', 'AG_campanha_X137', 'ACTIVE', now());
insert into public.meta_ads_diario (dia, ad_id, ad_nome, adset_id, adset_nome, campanha_id, campanha_nome, gasto, impressoes, cliques, conversas, atualizado_em)
values ((now() at time zone 'America/Sao_Paulo')::date, 'adX137', 'AG_anuncio_X137', 'asX137', 'AG_conjunto_X137', 'cX137', 'AG_campanha_X137', 30, 900, 12, 1, now());
select public.agente_trafego_retrato(14) as r1 \gset
update public.meta_ads_campanhas_dono set dono = 'agencia', classificada_em = now() where campanha_id = 'cX137';
select public.agente_trafego_retrato(14) as r2 \gset

select sim.confere('campanha nova aparece no retrato do agente como sem_dono (anúncio, conjunto e lista)',
  (select x ->> 'dono' from jsonb_array_elements(:'r1'::jsonb -> 'por_anuncio') x where x ->> 'ad_id' = 'adX137') = 'sem_dono'
    and (select x ->> 'dono' from jsonb_array_elements(:'r1'::jsonb -> 'por_conjunto') x where x ->> 'conjunto_id' = 'asX137') = 'sem_dono'
    and (select x ->> 'dono' from jsonb_array_elements(:'r1'::jsonb -> 'campanhas_dono') x where x ->> 'campanha_id' = 'cX137') = 'sem_dono',
  left(:'r1'::jsonb ->> 'campanhas_dono', 300));
select sim.confere('liberada para a agência, o retrato diz dono agencia; as campanhas que já existiam seguem dharma',
  (select x ->> 'dono' from jsonb_array_elements(:'r2'::jsonb -> 'por_anuncio') x where x ->> 'ad_id' = 'adX137') = 'agencia'
    and not exists (select 1 from jsonb_array_elements(:'r2'::jsonb -> 'por_anuncio') x where x ->> 'ad_id' <> 'adX137' and x ->> 'campanha_id' is not null and x ->> 'dono' <> 'dharma'),
  (select string_agg(x ->> 'ad_id' || '=' || coalesce(x ->> 'dono', '?'), ', ') from jsonb_array_elements(:'r2'::jsonb -> 'por_anuncio') x));
select sim.confere('os números do retrato não mudaram com os campos novos (fora a campanha que entrou)',
  (:'antes'::jsonb -> 'escada') = (:'r2'::jsonb -> 'escada') and (:'antes'::jsonb -> 'por_cidade') = (:'r2'::jsonb -> 'por_cidade'),
  'mudou');
