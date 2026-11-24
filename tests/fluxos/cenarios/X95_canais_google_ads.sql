-- id: X95
-- titulo: Tela Canais + Google Ads (Ricardo, 23/11 16h17: "Todos os canais de qualificação remotos precisam estar dentro do CRM"). O gasto do Google entra pela coleta (google_ads_gravar, só a chave de serviço); no dia coletado o custo digitado à mão é ignorado, nunca somado; o card Canais ganha status e retorno (vazio sem gasto); o selo do Google só aparece depois da 1ª coleta e acusa coleta parada
-- tipo: atual
-- premissa (24/11, portão da 0378/0379): a cópia do banco vem do backup do dia e já traz a coleta real do Google — o cenário
-- começa sem ela (o banco do cenário é descartável)
delete from public.google_ads_diario; delete from public.google_ads_palavras; delete from public.google_ads_campanhas; delete from public.google_ads_conta;

-- A) sem coleta ainda: nenhum selo do Google; o custo digitado conta sozinho
select sim.como('admin');
select sim.confere('antes da 1ª coleta não há selo do Google', not (public.status_operacao() ? 'google'), public.status_operacao()::text);
select public.canal_custo_gravar('google_ads', (now() at time zone 'America/Sao_Paulo')::date - 3, 40, 'X95 à mão');
select public.canal_custo_gravar('google_ads', (now() at time zone 'America/Sao_Paulo')::date, 30, 'X95 à mão hoje');
select sim.confere('sem coleta, o custo do Google é o digitado',
  (select valor from public.v_canal_custo_dia where canal = 'google_ads' and dia = (now() at time zone 'America/Sao_Paulo')::date) = 30, null);

-- B) a porta: login comum não grava; a coleta (service role) grava
set role authenticated;
select sim.recusa($q$ select public.google_ads_gravar('[]', '[]', '[]', null) $q$) as recusa_login \gset
reset role;
select sim.confere('admin logado não chama google_ads_gravar', :'recusa_login' <> '', :'recusa_login');
select sim._servico();
select public.google_ads_gravar(
  jsonb_build_array(jsonb_build_object('id', '24534613198', 'conta_id', '7560120293', 'nome', 'Campaign #1', 'status', 'ENABLED',
                                       'status_veiculacao', 'ELIGIBLE', 'tipo', 'SEARCH', 'orcamento_diario', 50, 'estrategia_lances', 'MAXIMIZE_CLICKS', 'teto_cpc', 2.5)),
  jsonb_build_array(jsonb_build_object('dia', (now() at time zone 'America/Sao_Paulo')::date, 'campanha_id', '24534613198', 'campanha_nome', 'Campaign #1',
                                       'impressoes', 900, 'cliques', 40, 'custo', 50, 'conversoes', 3, 'parcela_impressoes', 0.12, 'parcela_perdida_classificacao', 0.80)),
  jsonb_build_array(jsonb_build_object('grupo_id', '1', 'criterio_id', '10', 'campanha_id', '24534613198', 'grupo_nome', 'Grupo 1', 'palavra', 'internet fibra',
                                       'correspondencia', 'PHRASE', 'status', 'ENABLED', 'status_veiculacao', 'RARELY_SERVED')),
  jsonb_build_object('id', '756-012-0293', 'nome', 'Nio Internet', 'moeda', 'BRL', 'status', 'ENABLED', 'limite_aprovado', 500, 'gasto_servido', 200));
select sim.confere('a coleta gravou campanha, dia, palavra e conta',
  (select count(*) from public.google_ads_campanhas) = 1 and (select count(*) from public.google_ads_diario) = 1
  and (select count(*) from public.google_ads_palavras) = 1 and (select saldo from public.google_ads_conta where conta_id = '7560120293') = 300, null);

-- C) uma fonte por fato: hoje vale o coletado (50), não 50 + 30; o dia sem coleta segue com o digitado
select sim.confere('no dia coletado, o custo do Google é só o da coleta (o digitado é ignorado)',
  (select sum(valor) from public.v_canal_custo_dia where canal = 'google_ads' and dia = (now() at time zone 'America/Sao_Paulo')::date) = 50,
  (select string_agg(valor || ' ' || origem_do_dado, ' + ') from public.v_canal_custo_dia where canal = 'google_ads' and dia = (now() at time zone 'America/Sao_Paulo')::date));
select sim.confere('o dia sem coleta continua com o digitado',
  (select valor from public.v_canal_custo_dia where canal = 'google_ads' and dia = (now() at time zone 'America/Sao_Paulo')::date - 3) = 40, null);
select sim.como('admin');
select sim.confere('custo à mão do Google num dia já coletado é recusado',
  sim.recusa($q$ select public.canal_custo_gravar('google_ads', (now() at time zone 'America/Sao_Paulo')::date, 10, null) $q$) like '%já veio da coleta%', null);

-- C2) a conferência (0370): o dia digitado e coletado aparece em amarelo; o card bate com as fontes
select sim.confere('conferência: custo do Google digitado e coletado no mesmo dia = atenção',
  (select x->>'nivel' from jsonb_array_elements(public.conferencia_itens()) x where x->>'codigo' = 'google_custo_fonte') = 'atencao',
  (select x::text from jsonb_array_elements(public.conferencia_itens()) x where x->>'codigo' = 'google_custo_fonte'));

-- D) o card: status e retorno
select sim.confere('Google no ar no card, com o gasto de 7 dias (40 + 50)',
  (select status = 'no_ar' and gasto = 90 and aba = 'google' from public.canais_resumo(7) where canal = 'google_ads'),
  (select status || ' · ' || coalesce(gasto::text, '-') || ' · ' || coalesce(aba, '-') from public.canais_resumo(7) where canal = 'google_ads'));
select sim.confere('retorno = comissão ÷ gasto (0 quando gastou sem vender)',
  (select retorno = round(comissao_prevista / gasto, 2) from public.canais_resumo(7) where canal = 'google_ads'), null);
select sim.confere('canal sem gasto tem retorno vazio (nem 0 nem infinito)',
  (select bool_and(retorno is null) from public.canais_resumo(7) where coalesce(gasto, 0) = 0), null);
select sim.confere('canal que nunca subiu aparece como nunca_subiu',
  (select status from public.canais_resumo(7) where canal = 'sdr') = 'nunca_subiu', null);
select sim.confere('canais no ar ficam em cima',
  not exists (select 1 from (select status, row_number() over () as i from public.canais_resumo(7)) a
               join (select status, row_number() over () as i from public.canais_resumo(7)) b on b.i > a.i
              where a.status not in ('no_ar', 'sem_entrega') and b.status in ('no_ar', 'sem_entrega')), null);

-- E) selo: ok com a coleta em dia; alerta com a coleta parada há mais de 45 min
select sim.confere('selo do Google aparece depois da coleta',
  public.status_operacao()->'google'->>'nivel' = 'ok', public.status_operacao()->>'google');
update public.google_ads_conta set coletado_em = now() - interval '50 minutes';
select sim.confere('coleta do Google parada há 50 min deixa o selo em alerta',
  public.status_operacao()->'google'->>'nivel' = 'alerta', public.status_operacao()->>'google');
update public.google_ads_conta set coletado_em = now() - interval '3 hours';
select sim.confere('conferência: coleta do Google parada há 3 h = falha',
  (select x->>'nivel' from jsonb_array_elements(public.conferencia_itens()) x where x->>'codigo' = 'google_custo_fonte') = 'falha', null);
update public.google_ads_conta set coletado_em = now(), saldo = 0;
select sim.confere('pré-pago zerado = falha',
  public.status_operacao()->'google'->>'nivel' = 'falha', public.status_operacao()->>'google');
