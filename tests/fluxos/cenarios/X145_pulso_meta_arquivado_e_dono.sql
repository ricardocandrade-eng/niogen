-- id: X145
-- titulo: 0421 (Ricardo 26/11, "Corrige o aviso"): anúncio que a Meta parou de listar (campanha arquivada) deixa de contar como "problema de entrega", e os avisos de anúncio e de gasto do pulso dizem de quem é (Dharma · agência)
-- tipo: atual
select sim.como('servico');

-- três anúncios: um da Dharma com problema (a campanha vai ser arquivada), dois da agência (um ativo, um com problema)
insert into public.meta_ads_anuncios (ad_id, ad_nome, adset_id, adset_nome, campanha_id, campanha_nome, status_efetivo, atualizado_em)
values ('adX145a', 'C1_anuncio_X145', 'asX145d', 'C1_conjunto_X145', 'cX145d', 'C1_campanha_X145', 'WITH_ISSUES', now() - interval '1 day'),
       ('adX145b', 'AG_ativo_X145',   'asX145g', 'AG_conjunto_X145', 'cX145g', 'AG_campanha_X145', 'ACTIVE',      now() - interval '1 day'),
       ('adX145c', 'AG_problema_X145','asX145g', 'AG_conjunto_X145', 'cX145g', 'AG_campanha_X145', 'WITH_ISSUES', now() - interval '1 day');
update public.meta_ads_campanhas_dono set dono = 'dharma',  classificada_em = now() where campanha_id = 'cX145d';
update public.meta_ads_campanhas_dono set dono = 'agencia', classificada_em = now() where campanha_id = 'cX145g';

-- 1) coleta que voltou vazia (falha da chamada) não arquiva ninguém
select public.meta_ads_gravar('[]'::jsonb, '[]'::jsonb) \gset
select sim.confere('lista vazia da Meta não arquiva anúncio',
  (select status_efetivo from public.meta_ads_anuncios where ad_id = 'adX145a') = 'WITH_ISSUES',
  (select status_efetivo from public.meta_ads_anuncios where ad_id = 'adX145a'));

-- 2) a campanha da Dharma foi arquivada: a Meta só lista os dois da agência
select public.meta_ads_gravar('[]'::jsonb, '[
  {"id":"adX145b","name":"AG_ativo_X145","effective_status":"ACTIVE","adset_id":"asX145g","adset":{"name":"AG_conjunto_X145"},"campaign_id":"cX145g","campaign":{"name":"AG_campanha_X145"}},
  {"id":"adX145c","name":"AG_problema_X145","effective_status":"WITH_ISSUES","adset_id":"asX145g","adset":{"name":"AG_conjunto_X145"},"campaign_id":"cX145g","campaign":{"name":"AG_campanha_X145"}}
]'::jsonb) \gset
select sim.confere('anúncio que sumiu da lista da Meta vira ARCHIVED; os que vieram ficam como vieram',
  (select status_efetivo from public.meta_ads_anuncios where ad_id = 'adX145a') = 'ARCHIVED'
    and (select status_efetivo from public.meta_ads_anuncios where ad_id = 'adX145b') = 'ACTIVE'
    and (select status_efetivo from public.meta_ads_anuncios where ad_id = 'adX145c') = 'WITH_ISSUES',
  (select string_agg(ad_id || '=' || status_efetivo, ', ' order by ad_id) from public.meta_ads_anuncios where ad_id like 'adX145%'));

-- 3) o aviso: sobrou 1 com problema, e é da agência — o pulso diz de quem é
select sim.confere('aviso de problema de entrega diz de quem é o anúncio',
  public._pulso_meta_anuncios_donos('WITH_ISSUES') = ' (agência 1)',
  public._pulso_meta_anuncios_donos('WITH_ISSUES'));
select sim.confere('o pulso mostra "1 anúncio(s) com problema de entrega (agência 1)" — o da campanha arquivada não conta',
  public.pulso_operacao()::text like '%1 anúncio(s) com problema de entrega (agência 1)%',
  left(public.pulso_operacao() -> 'elos' ->> 'meta', 400));

-- 4) o gasto do dia: com agência no meio, diz quanto é de cada um; só Dharma, texto como antes
insert into public.meta_ads_diario (dia, ad_id, ad_nome, adset_id, adset_nome, campanha_id, campanha_nome, gasto, impressoes, cliques, conversas, atualizado_em)
values ('2020-01-01', 'adX145a', 'C1_anuncio_X145', 'asX145d', 'C1_conjunto_X145', 'cX145d', 'C1_campanha_X145', 43.56, 900, 8, 2, now()),
       ('2020-01-01', 'adX145b', 'AG_ativo_X145',   'asX145g', 'AG_conjunto_X145', 'cX145g', 'AG_campanha_X145', 25.09, 800, 3, 0, now()),
       ('2020-01-02', 'adX145a', 'C1_anuncio_X145', 'asX145d', 'C1_conjunto_X145', 'cX145d', 'C1_campanha_X145', 50,    900, 8, 2, now());
select sim.confere('gasto com agência no dia: "(Dharma R$ 43,56 · agência R$ 25,09)"',
  public._pulso_meta_gasto_donos('2020-01-01') = ' (Dharma R$ 43,56 · agência R$ 25,09)',
  public._pulso_meta_gasto_donos('2020-01-01'));
select sim.confere('dia só com gasto da Dharma: nada acrescentado ao texto',
  public._pulso_meta_gasto_donos('2020-01-02') = '',
  public._pulso_meta_gasto_donos('2020-01-02'));

-- 5) o anúncio voltou a ser listado (desarquivado): vale o status que a Meta mandar
select public.meta_ads_gravar('[]'::jsonb, '[
  {"id":"adX145a","name":"C1_anuncio_X145","effective_status":"PAUSED","adset_id":"asX145d","adset":{"name":"C1_conjunto_X145"},"campaign_id":"cX145d","campaign":{"name":"C1_campanha_X145"}},
  {"id":"adX145b","name":"AG_ativo_X145","effective_status":"ACTIVE","adset_id":"asX145g","adset":{"name":"AG_conjunto_X145"},"campaign_id":"cX145g","campaign":{"name":"AG_campanha_X145"}},
  {"id":"adX145c","name":"AG_problema_X145","effective_status":"ACTIVE","adset_id":"asX145g","adset":{"name":"AG_conjunto_X145"},"campaign_id":"cX145g","campaign":{"name":"AG_campanha_X145"}}
]'::jsonb) \gset
select sim.confere('anúncio que voltou à lista sai de ARCHIVED para o status da Meta',
  (select status_efetivo from public.meta_ads_anuncios where ad_id = 'adX145a') = 'PAUSED',
  (select status_efetivo from public.meta_ads_anuncios where ad_id = 'adX145a'));
