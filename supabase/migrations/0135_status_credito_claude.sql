-- NIOGEN | supabase/migrations/0135_status_credito_claude.sql | 12/11/2026 — Claude Code
-- 12/11 ~03h05: a conta da Anthropic da Mari ficou SEM CRÉDITO (as baterias do portão desta noite gastaram o saldo). O selo da
-- Mari não acusaria: no nó 6 · Claude o n8n devolve message "Bad request" e o texto "credit balance is too low" só na descrição.
-- status_operacao() passa a ler também auditoria_mari.erro e balanco_diario.erro (mesma conta, texto completo).

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
  -- 0135: a Mari grava só "Bad request" (o texto do crédito vem na descrição do erro do n8n); a auditoria e o balanço usam a
  -- MESMA conta da Anthropic e gravam o texto completo → também acusam o "sem crédito".
  select greatest(v_credito, (select max(coalesce(a.fim, a.pedido_em)) from public.auditoria_mari a
                               where a.erro ilike '%credit balance%' and coalesce(a.fim, a.pedido_em) > now() - interval '6 hours'),
                             (select max(b.criado_em) from public.balanco_diario b
                               where b.erro ilike '%credit balance%' and b.criado_em > now() - interval '6 hours'))
    into v_credito;
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
