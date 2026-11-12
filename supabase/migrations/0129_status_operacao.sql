-- NIOGEN | supabase/migrations/0129_status_operacao.sql | 12/11/2026 — Claude Code
-- Ricardo, 12/11 ~01h: no rodapé fixo do menu, acima do Sair, dois selos lado a lado — "Mari ok" e "Meta N no ar" — que acusam
-- qualquer inconsistência: falha da API do Claude (sem crédito inclusive), cliente esperando a Mari, erros de fluxo, e campanha
-- que caiu por falha no pagamento, conta desativada, anúncio reprovado, coleta parada ou campanha no ar sem entrega.
--   1. meta_ads_conta_saldo + account_status / disable_reason (lidos pelo nó 9 do meta_ads_coleta, campos novos na Graph API).
--   2. meta_ads_gravar_saldo grava os dois.
--   3. status_operacao(): uma chamada só (orçamento de desempenho, regra 19), qualquer usuário logado com perfil.
--      nivel: ok | alerta | falha · texto curto do selo · motivos[] (o "por quê" no title) · link da tela.

alter table public.meta_ads_conta_saldo add column if not exists account_status int;
alter table public.meta_ads_conta_saldo add column if not exists disable_reason int;

create or replace function public.meta_ads_gravar_saldo(p_act text, p_conta jsonb, p_ciclo jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_saldo numeric; v_limite numeric; v_gasto numeric; v_pct numeric; v_dia int; v_prox date; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_ciclo jsonb;
begin
  if p_conta is null or p_conta ? 'error' or not (p_conta ? 'balance') then
    return jsonb_build_object('ok', false, 'motivo', 'sem balance na resposta da Meta', 'erro', p_conta->'error'->>'message');
  end if;
  v_saldo := round((p_conta->>'balance')::numeric / 100, 2);
  v_gasto := case when p_conta ? 'amount_spent' then round((p_conta->>'amount_spent')::numeric / 100, 2) end;
  v_ciclo := case when jsonb_typeof(p_ciclo->'data') = 'array' then (select x from jsonb_array_elements(p_ciclo->'data') x
                                                                       order by x->>'created_time' desc nulls last limit 1) end;
  v_limite := case when v_ciclo ? 'threshold_amount' then round((v_ciclo->>'threshold_amount')::numeric / 100, 2) end;
  select valor into v_pct from public.config_meta_ads_regras where parceiro_id = 'dharma' and chave = 'meta_imposto_estimado_pct';
  select valor::int into v_dia from public.config_meta_ads_regras where parceiro_id = 'dharma' and chave = 'meta_cobranca_dia_mensal';
  if v_dia between 1 and 28 then
    v_prox := make_date(extract(year from v_hoje)::int, extract(month from v_hoje)::int, v_dia);
    if v_prox < v_hoje then v_prox := (v_prox + interval '1 month')::date; end if;
  end if;
  insert into public.meta_ads_conta_saldo as s (act_id, moeda, saldo, imposto_estimado, limite_cobranca, proxima_cobranca_em, fonte_data,
                                                gasto_total, coletado_em, account_status, disable_reason)
  values (p_act, p_conta->>'currency', v_saldo, case when v_pct is not null then round(v_saldo * v_pct / 100, 2) end,
          v_limite, v_prox, 'config', v_gasto, now(), (p_conta->>'account_status')::int, (p_conta->>'disable_reason')::int)
  on conflict (act_id) do update set moeda = excluded.moeda, saldo = excluded.saldo, imposto_estimado = excluded.imposto_estimado,
    limite_cobranca = excluded.limite_cobranca, proxima_cobranca_em = excluded.proxima_cobranca_em, fonte_data = excluded.fonte_data,
    gasto_total = excluded.gasto_total, coletado_em = excluded.coletado_em,
    account_status = coalesce(excluded.account_status, s.account_status), disable_reason = coalesce(excluded.disable_reason, s.disable_reason);
  return jsonb_build_object('ok', true, 'saldo', v_saldo, 'limite', v_limite, 'proxima', v_prox, 'ciclo_lido', v_ciclo is not null,
    'account_status', (p_conta->>'account_status')::int,
    'ciclo_erro', p_ciclo->'error'->>'message', 'ciclo_itens', case when jsonb_typeof(p_ciclo->'data') = 'array' then jsonb_array_length(p_ciclo->'data') end,
    'ciclo_campos', case when v_ciclo is not null then (select jsonb_agg(k) from jsonb_object_keys(v_ciclo) k) end);
end $$;
revoke all on function public.meta_ads_gravar_saldo(text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.meta_ads_gravar_saldo(text, jsonb, jsonb) to service_role;

create or replace function public.status_operacao()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  -- Mari
  m_nivel text := 'ok'; m_mot text[] := '{}'; m_texto text;
  v_credito timestamptz; v_claude int; v_claude_ult text; v_infra int; v_esperando int; v_alarme timestamptz; v_ult_resp timestamptz;
  v_bal_erro text;
  -- Meta
  a_nivel text := 'ok'; a_mot text[] := '{}'; a_texto text;
  v_ativas int; v_ads_ativos int; v_cobranca int; v_reprov int; v_problema int; v_coleta timestamptz; v_conta record;
  v_impr_hoje int; v_meta_err int; v_hora int := extract(hour from now() at time zone 'America/Sao_Paulo')::int;
begin
  if public.meu_perfil() is null and auth.role() is distinct from 'service_role' then
    raise exception 'status_operacao: sem perfil' using errcode = '42501';
  end if;

  -- ===== Mari =====
  -- Sem crédito na API do Claude: a mensagem da Anthropic diz "credit balance is too low" (nós 6/6r, balanço, qualquer fluxo).
  select max(created_at) into v_credito from public.mari_erros
   where created_at > now() - interval '6 hours' and (mensagem ilike '%credit balance%' or mensagem ilike '%billing%');
  select count(*), max(left(mensagem, 140)) into v_claude, v_claude_ult from public.mari_erros
   where created_at > now() - interval '30 minutes' and (no_n8n like '6%Claude%' or mensagem like 'Claude API:%');
  -- Erros de fluxo (Error Trigger: tem execution_id) dos fluxos da Mari na última hora; os do Meta Ads contam do lado do Meta.
  select count(*) into v_infra from public.mari_erros
   where created_at > now() - interval '60 minutes' and payload ? 'execution_id'
     and coalesce(payload->>'workflow', '') not in ('meta_ads_coleta');
  select count(*) into v_esperando from public.v_mari_sem_resposta;
  select min(avisado_em) into v_alarme from public.mari_alarmes where resolvido_em is null and avisado_em is not null;
  select max(created_at) into v_ult_resp from public.mari_turnos where papel = 'mari';
  select erro into v_bal_erro from public.balanco_diario where criado_em > now() - interval '24 hours' order by criado_em desc limit 1;

  if v_credito is not null or v_bal_erro ilike '%credit balance%' then
    m_nivel := 'falha'; m_texto := 'Mari sem crédito';
    m_mot := m_mot || format('API do Claude sem crédito (último erro %s) — recarregar em console.anthropic.com',
                             to_char(coalesce(v_credito, now()) at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'));
  end if;
  if v_claude >= 2 then
    m_nivel := 'falha'; m_texto := coalesce(m_texto, 'Mari falhando');
    m_mot := m_mot || format('%s falha(s) da API do Claude em 30 min: %s', v_claude, v_claude_ult);
  elsif v_claude = 1 then
    if m_nivel = 'ok' then m_nivel := 'alerta'; end if;
    m_mot := m_mot || format('1 falha da API do Claude em 30 min: %s', v_claude_ult);
  end if;
  if v_esperando > 0 then
    m_nivel := 'falha'; m_texto := coalesce(m_texto, 'Mari parada');
    m_mot := m_mot || format('%s cliente(s) esperando resposta da Mari', v_esperando);
  elsif v_alarme is not null then
    m_nivel := 'falha'; m_texto := coalesce(m_texto, 'Mari parada');
    m_mot := m_mot || format('alarme de silêncio aberto desde %s', to_char(v_alarme at time zone 'America/Sao_Paulo', 'HH24:MI'));
  end if;
  if v_infra >= 3 then
    if m_nivel = 'ok' then m_nivel := 'alerta'; end if;
    m_mot := m_mot || format('%s erro(s) de fluxo no n8n na última hora (ver Mari › Erros)', v_infra);
  elsif v_infra > 0 then
    m_mot := m_mot || format('%s erro(s) isolado(s) de fluxo na última hora', v_infra);
  end if;
  if v_bal_erro is not null and v_bal_erro not ilike '%credit balance%' then
    if m_nivel = 'ok' then m_nivel := 'alerta'; end if;
    m_mot := m_mot || format('balanço diário falhou: %s', left(v_bal_erro, 120));
  end if;
  m_texto := coalesce(m_texto, case m_nivel when 'ok' then 'Mari ok' else 'Mari com alerta' end);
  if v_ult_resp is not null then
    m_mot := m_mot || format('última resposta da Mari: %s', to_char(v_ult_resp at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'));
  end if;

  -- ===== Meta Ads =====
  select count(distinct campanha_id), count(*) into v_ativas, v_ads_ativos from public.meta_ads_anuncios where status_efetivo = 'ACTIVE';
  select count(*) filter (where status_efetivo = 'PENDING_BILLING_INFO'),
         count(*) filter (where status_efetivo = 'DISAPPROVED'),
         count(*) filter (where status_efetivo = 'WITH_ISSUES'),
         max(atualizado_em)
    into v_cobranca, v_reprov, v_problema, v_coleta
    from public.meta_ads_anuncios;
  select account_status, disable_reason, saldo, limite_cobranca into v_conta
    from public.meta_ads_conta_saldo order by coletado_em desc limit 1;
  select coalesce(sum(impressoes), 0) into v_impr_hoje from public.meta_ads_diario
   where dia = (now() at time zone 'America/Sao_Paulo')::date;
  select count(*) into v_meta_err from public.mari_erros
   where created_at > now() - interval '60 minutes' and payload->>'workflow' = 'meta_ads_coleta';

  -- account_status da Graph API: 1 ativa · 2 desativada · 3 pagamento pendente · 7 revisão de risco · 8 acerto pendente
  -- · 9 carência (pagamento falhou, ainda entrega) · 100 fechando · 101 fechada.
  if v_conta.account_status in (3, 8) or v_cobranca > 0 then
    a_nivel := 'falha'; a_texto := 'Meta: pagamento';
    a_mot := a_mot || 'falha no pagamento da conta de anúncios — campanhas paradas até pagar (BM › Cobrança)';
  elsif v_conta.account_status in (2, 100, 101) then
    a_nivel := 'falha'; a_texto := 'Meta: conta bloqueada';
    a_mot := a_mot || format('conta de anúncios desativada (status %s, motivo %s) — ver no BM', v_conta.account_status, coalesce(v_conta.disable_reason, 0));
  elsif v_conta.account_status = 9 then
    a_nivel := 'alerta';
    a_mot := a_mot || 'pagamento recusado: conta em carência, ainda entrega mas vai parar — trocar/pagar no BM › Cobrança';
  elsif v_conta.account_status = 7 then
    a_nivel := 'alerta';
    a_mot := a_mot || 'conta em revisão de risco da Meta';
  end if;
  if v_ativas = 0 and a_nivel <> 'falha' then
    a_nivel := 'falha'; a_texto := 'Meta: nada no ar';
    a_mot := a_mot || 'nenhuma campanha com anúncio ativo';
  end if;
  if v_reprov > 0 then
    if a_nivel = 'ok' then a_nivel := 'alerta'; end if;
    a_mot := a_mot || format('%s anúncio(s) reprovado(s)', v_reprov);
  end if;
  if v_problema > 0 then
    if a_nivel = 'ok' then a_nivel := 'alerta'; end if;
    a_mot := a_mot || format('%s anúncio(s) com problema de entrega', v_problema);
  end if;
  if v_coleta is null or v_coleta < now() - interval '45 minutes' then
    if a_nivel = 'ok' then a_nivel := 'alerta'; end if;
    a_mot := a_mot || format('coleta do Meta parada desde %s — o status pode estar velho',
                             coalesce(to_char(v_coleta at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), 'sempre'));
  elsif v_meta_err >= 2 then
    if a_nivel = 'ok' then a_nivel := 'alerta'; end if;
    a_mot := a_mot || format('%s erro(s) na coleta do Meta na última hora (token ou permissão?)', v_meta_err);
  end if;
  if v_ativas > 0 and v_impr_hoje = 0 and v_hora between 10 and 22 then
    if a_nivel = 'ok' then a_nivel := 'alerta'; end if;
    a_mot := a_mot || 'campanha no ar mas sem nenhuma impressão hoje';
  end if;
  a_texto := coalesce(a_texto, case when a_nivel = 'ok' then format('Meta %s no ar', v_ativas)
                                    else format('Meta %s no ar', v_ativas) end);
  a_mot := a_mot || format('%s campanha(s) e %s anúncio(s) ativos · %s impressões hoje', v_ativas, v_ads_ativos, v_impr_hoje);

  return jsonb_build_object(
    'agora', now(),
    'mari', jsonb_build_object('nivel', m_nivel, 'texto', m_texto, 'motivos', to_jsonb(m_mot), 'href', 'mari.html'),
    'meta', jsonb_build_object('nivel', a_nivel, 'texto', a_texto, 'motivos', to_jsonb(a_mot), 'href', 'metaads.html'));
end $$;
revoke all on function public.status_operacao() from public, anon;
grant execute on function public.status_operacao() to authenticated, service_role;
