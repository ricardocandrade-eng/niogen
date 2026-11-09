-- NIOGEN | supabase/migrations/0077_resumo_diario.sql | 09/11/2026 — Claude Code (Prompt_rodada_noturna_ondas2e3_091126_0100, item 5 · onda 3.2 fase 1)
-- Por quê: o Ricardo quer abrir o dia sabendo o que aconteceu ontem sem entrar em 4 telas. Fase 1 = conteúdo pronto; o ENVIO fica
--          desligado até decidir o canal (mesma decisão do alarme da Mari: template WhatsApp × bot do Telegram).
-- O quê (só aditivo):
--   resumo_diario(p_dia) → {dia, dados, texto}: vendas criadas/qualificadas/pedidos/biometrias/instaladas do dia · gasto Meta e custo por
--   conversa · conversas paradas (com humano há > N h, cliente sem resposta há > N h) · prazos do contrato vencendo (agendar 4 h, docs 15 d)
--   · pendências com terceiro · ritmo da meta (painel_meta_ritmo, a mesma conta da faixa do Painel). Texto ≤ 12 linhas, sem CPF nem telefone.
--   Só admin (tela) ou service_role (n8n). Núcleo: sem a Mari, as linhas dela saem zeradas e o resto funciona.

insert into public.config_regras (chave, valor, descricao) values
  ('resumo_parada_horas', '2', 'Resumo diário: conversa com humano (handoff) ou cliente sem resposta há mais que isto conta como parada')
on conflict (chave) do nothing;

create or replace function public.resumo_diario(p_dia date default ((now() at time zone 'America/Sao_Paulo')::date - 1))
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  tz constant text := 'America/Sao_Paulo';
  hoje date := p_dia + 1;               -- o dia em que o resumo é lido
  h_par numeric := coalesce((public.config_regra('resumo_parada_horas', '2'))::text::numeric, 2);
  h_ag numeric := coalesce((public.config_regra('prazo_agendar_horas', '4'))::text::numeric, 4);
  d_docs int := coalesce((public.config_regra('prazo_docs_dias', '15'))::text::int, 15);
  n_criadas int; n_qualif int; n_pedidos int; n_bio int; n_inst int;
  gasto numeric; conv_meta int;
  par_humano int; par_cliente int;
  ag_venc int; ag_hoje int; ag_amanha int; dc_venc int; dc_hoje int; dc_amanha int;
  esp int; esp_venc int;
  ritmo jsonb;
  dados jsonb; linhas text[] := '{}';
  dows text[] := array['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sáb'];
  meses text[] := array['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
  nome_mes text;
  brl text;
begin
  if auth.role() is distinct from 'service_role' and auth.uid() is not null and public.meu_perfil() is distinct from 'admin' then
    raise exception 'resumo_diario: só admin' using errcode = '42501';
  end if;

  select count(*) into n_criadas from public.vendas where (criado_em at time zone tz)::date = p_dia;
  select count(*) into n_qualif from public.mari_conversas
   where handoff_motivo = 'dados_completos' and (handoff_em at time zone tz)::date = p_dia and coalesce(canal, '') <> 'teste';
  select count(*) into n_pedidos from public.vendas where (nio_pedido_em at time zone tz)::date = p_dia;
  select count(*) into n_bio from public.vendas where (biometria_validada_em at time zone tz)::date = p_dia;
  select count(*) into n_inst from public.vendas where (instalado_em at time zone tz)::date = p_dia and status <> 'saida';

  select coalesce(sum(m.gasto), 0), coalesce(sum(m.conversas_meta), 0) into gasto, conv_meta from public.v_meta_ads_dia m where m.dia = p_dia;

  -- Conversas paradas agora (no momento em que o resumo roda), conversas de teste fora.
  select count(*) filter (where q.vez = 'humano' and q.vez_desde <= now() - make_interval(secs => h_par * 3600)),
         count(*) filter (where q.vez = 'mari' and q.vez_desde <= now() - make_interval(secs => h_par * 3600))
    into par_humano, par_cliente
    from public.v_mari_quadro q where not coalesce(q.teste, false) and q.coluna <> 'encerrada';

  -- Prazos do contrato (no dia de leitura): agendar a instalação em h_ag horas; documentos em d_docs dias.
  select count(*) filter (where p < now()),
         count(*) filter (where p >= now() and (p at time zone tz)::date = hoje),
         count(*) filter (where (p at time zone tz)::date = hoje + 1)
    into ag_venc, ag_hoje, ag_amanha
    from (select vendido_em + make_interval(secs => h_ag * 3600) as p from public.vendas where status = '1_vendido' and vendido_em is not null) x;
  select count(*) filter (where p < now()),
         count(*) filter (where p >= now() and (p at time zone tz)::date = hoje),
         count(*) filter (where (p at time zone tz)::date = hoje + 1)
    into dc_venc, dc_hoje, dc_amanha
    from (select instalado_em + make_interval(days => d_docs) as p from public.vendas
           where status = '3_instalado' and instalado_em is not null and docs_entregues_em is null) x;

  select count(*), count(*) filter (where revisar_em <= hoje) into esp, esp_venc
    from public.venda_pendencias where encerrada_em is null;

  ritmo := public.painel_meta_ritmo(hoje);
  nome_mes := meses[extract(month from hoje)::int];
  brl := replace(to_char(gasto, 'FM999990.00'), '.', ',');

  dados := jsonb_build_object(
    'vendas', jsonb_build_object('criadas', n_criadas, 'qualificadas_mari', n_qualif, 'pedidos', n_pedidos, 'biometrias', n_bio, 'instaladas', n_inst),
    'meta_ads', jsonb_build_object('gasto', gasto, 'conversas', conv_meta, 'custo_por_conversa', case when conv_meta > 0 then round(gasto / conv_meta, 2) end),
    'paradas', jsonb_build_object('com_humano', par_humano, 'cliente_sem_resposta', par_cliente, 'horas', h_par),
    'prazos', jsonb_build_object('agendar', jsonb_build_object('vencidos', ag_venc, 'hoje', ag_hoje, 'amanha', ag_amanha),
                                 'docs', jsonb_build_object('vencidos', dc_venc, 'hoje', dc_hoje, 'amanha', dc_amanha)),
    'em_espera', jsonb_build_object('abertas', esp, 'revisar_hoje_ou_antes', esp_venc),
    'ritmo', ritmo);

  linhas := linhas || format('📊 NIOGEN · resumo de %s %s', dows[extract(dow from p_dia)::int + 1], to_char(p_dia, 'DD/MM'));
  linhas := linhas || format('Vendas: %s nova%s · %s qualificada%s pela Mari · %s pedido%s · %s biometria%s · %s instalada%s',
    n_criadas, case when n_criadas = 1 then '' else 's' end, n_qualif, case when n_qualif = 1 then '' else 's' end,
    n_pedidos, case when n_pedidos = 1 then '' else 's' end, n_bio, case when n_bio = 1 then '' else 's' end,
    n_inst, case when n_inst = 1 then '' else 's' end);
  linhas := linhas || case when conv_meta > 0
    then format('Meta Ads: R$ %s · %s conversa%s → R$ %s por conversa', brl, conv_meta, case when conv_meta = 1 then '' else 's' end,
                replace(to_char(round(gasto / conv_meta, 2), 'FM999990.00'), '.', ','))
    else format('Meta Ads: R$ %s · nenhuma conversa', brl) end;
  linhas := linhas || format('Paradas agora (+%s h): %s com humano sem resposta · %s cliente esperando a Mari',
    replace(h_par::text, '.', ','), par_humano, par_cliente);
  linhas := linhas || case when ag_venc + ag_hoje + ag_amanha + dc_venc + dc_hoje + dc_amanha = 0
    then 'Prazos do contrato: nada vencendo hoje nem amanhã ✓'
    else format('Prazos do contrato: agendar %s h — %s vencido(s), %s hoje, %s amanhã · docs %s d — %s vencido(s), %s hoje, %s amanhã',
                h_ag, ag_venc, ag_hoje, ag_amanha, d_docs, dc_venc, dc_hoje, dc_amanha) end;
  if esp > 0 then
    linhas := linhas || format('Em espera (terceiro): %s · %s para revisar hoje', esp, esp_venc);
  end if;
  if ritmo is not null and (ritmo->>'meta')::int > 0 then
    linhas := linhas || case when (ritmo->>'faltam')::int = 0
      then format('Meta de %s: %s/%s instaladas — batida ✓', nome_mes, ritmo->>'instaladas', ritmo->>'meta')
      else format('Meta de %s: %s/%s instaladas · faltam %s em %s dias → %s por dia', nome_mes, ritmo->>'instaladas', ritmo->>'meta',
                  ritmo->>'faltam', ritmo->>'dias_restantes', replace(ritmo->>'por_dia', '.', ',')) end;
  end if;

  return jsonb_build_object('dia', p_dia, 'gerado_em', now(), 'dados', dados, 'texto', array_to_string(linhas, E'\n'));
end $$;
revoke all on function public.resumo_diario(date) from public, anon;
grant execute on function public.resumo_diario(date) to authenticated, service_role;
