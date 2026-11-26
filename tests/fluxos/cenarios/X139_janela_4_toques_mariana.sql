-- id: X139
-- titulo: Janela de 24 h com 4 toques (15 min · 2 h · 6 h · ~20 h, F4 desligado) e a Mariana no toque de 2 h (0412)
-- tipo: atual
-- Ricardo, 25/11/2026: "podemos espaçar mais os horários" · "ela pode se apresentar como Mariana, num tom mais humano".
select sim.lead_novo('Joelma X139') as c \gset
select sim.cliente_escreve(:'c', 'quero pra home office, a internet daqui cai toda hora');
-- leva a conversa para ontem às 13h (Brasília): os toques caem todos dentro do horário 9–21
select (now() - ((date_trunc('day', now() at time zone 'America/Sao_Paulo') - interval '1 day' + interval '13 hours')
                 at time zone 'America/Sao_Paulo'))::text as recuo \gset
select sim.passa(:'c', :'recuo'::interval);
select ultima_msg_lead_at::text as l from public.mari_conversas where id = :'c' \gset

select sim.confere('config: tempos 15,120,360,0,1200 e Mariana no F2',
  (select texto from public.config_mari_textos where chave = 'cadencia_janela_minutos') = '15,120,360,0,1200'
  and (select texto from public.config_mari_textos where chave = 'cadencia_mariana_passo') = 'F2',
  (select string_agg(chave || '=' || texto, ' ') from public.config_mari_textos where chave like 'cadencia_%'));
select sim.confere('a arte fixa sai do F2 (é a vez da Mariana)',
  coalesce((select texto from public.config_mari_textos where chave = 'imagem_cadencia_passo'), '') <> 'F2',
  (select texto from public.config_mari_textos where chave = 'imagem_cadencia_passo'));

select sim.confere('a voz sai dos lembretes (Ricardo 26/11: voz robotizada)',
  coalesce((select texto from public.config_mari_textos where chave = 'audio_cadencia_passo'), '') = '',
  (select texto from public.config_mari_textos where chave = 'audio_cadencia_passo'));

-- F1 em 15 min
select sim.confere('logo depois: o próximo é o F1', sim.cadencia_ver(:'c', :'l'::timestamptz + interval '5 minutes') ->> 'proximo' = 'F1',
  sim.cadencia_ver(:'c', :'l'::timestamptz + interval '5 minutes')::text);
select sim.confere('F1 não se apresenta como Mariana', public.mari_cutucada_contexto(:'c', 'F1') ->> 'apresentar_como' is null,
  public.mari_cutucada_contexto(:'c', 'F1') ->> 'apresentar_como');
select sim.cadencia(:'l'::timestamptz + interval '25 minutes');
select sim.confere('F1 saiu', exists (select 1 from sim.envios where conversa = :'c' and por = 'cadencia:F1'),
  (select coalesce(string_agg(por, ' '), 'nenhuma') from sim.envios where conversa = :'c'));

-- F2 em 2 h (era 1 h), com a Mariana
select (sim.cadencia_ver(:'c', :'l'::timestamptz + interval '30 minutes') ->> 'em') as f2_em \gset
select sim.confere('F2 marcado para ~2 h depois da fala da Mari (não 1 h)',
  sim.cadencia_ver(:'c', :'l'::timestamptz + interval '30 minutes') ->> 'proximo' = 'F2'
  and :'f2_em'::timestamptz between :'l'::timestamptz + interval '110 minutes' and :'l'::timestamptz + interval '135 minutes',
  'l=' || :'l' || ' f2=' || :'f2_em');
select sim.confere('no F2 a cutucada se apresenta como Mariana', public.mari_cutucada_contexto(:'c', 'F2') ->> 'apresentar_como' = 'Mariana',
  public.mari_cutucada_contexto(:'c', 'F2')::text);
select sim.cadencia(:'l'::timestamptz + interval '140 minutes');
select sim.confere('F2 saiu e a reserva diz "Aqui é a Mariana, da Nio", sem "passando aqui" e sem emoji',
  exists (select 1 from sim.envios where conversa = :'c' and por = 'cadencia:F2' and texto like 'Oi! Aqui é a Mariana, da Nio. %'
                                     and texto not ilike '%passando aqui%' and texto not like '%😊%' and texto like '%?'),
  (select coalesce(string_agg(por || ': ' || texto, ' | '), 'nenhuma') from sim.envios where conversa = :'c'));
select sim.confere('depois do F2, a Mariana não se apresenta de novo',
  public.mari_cutucada_contexto(:'c', 'F3') ->> 'apresentar_como' is null
  and (public.mari_cutucada_contexto(:'c', 'F3') ->> 'ja_se_apresentou_mariana')::boolean,
  public.mari_cutucada_contexto(:'c', 'F3')::text);

-- F3 em 6 h (era 3 h)
select (sim.cadencia_ver(:'c', :'l'::timestamptz + interval '150 minutes') ->> 'em') as f3_em \gset
select sim.confere('F3 marcado para ~6 h depois da fala da Mari',
  sim.cadencia_ver(:'c', :'l'::timestamptz + interval '150 minutes') ->> 'proximo' = 'F3'
  and :'f3_em'::timestamptz between :'l'::timestamptz + interval '350 minutes' and :'l'::timestamptz + interval '375 minutes',
  'l=' || :'l' || ' f3=' || :'f3_em');
select sim.cadencia(:'l'::timestamptz + interval '380 minutes');

-- F4 desligado: depois do F3 vem a última chamada (F5)
select sim.confere('depois do F3 vem o F5 (F4 desligado)',
  sim.cadencia_ver(:'c', :'l'::timestamptz + interval '390 minutes') ->> 'proximo' = 'F5',
  sim.cadencia_ver(:'c', :'l'::timestamptz + interval '390 minutes')::text);
select sim.confere('na janela saíram F1, F2 e F3 — nenhum F4',
  (select string_agg(por, ' ' order by por) from sim.envios where conversa = :'c' and por like 'cadencia:F%') = 'cadencia:F1 cadencia:F2 cadencia:F3',
  (select coalesce(string_agg(por, ' ' order by por), 'nenhuma') from sim.envios where conversa = :'c' and por like 'cadencia:F%'));
