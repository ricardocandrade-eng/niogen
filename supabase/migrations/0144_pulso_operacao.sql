-- NIOGEN | supabase/migrations/0144_pulso_operacao.sql | 12/11/2026 — Claude Code
-- docs/Prompt_pulso_live_121126_1035.md (Ricardo, 12/11 10h16): com pouco lead qualificado chegando, saber se o dia está fraco ou se
-- algo quebrou. Faixa de pulso no topo da Live: Meta Ads → Entrada → Mari → Fluxos n8n + funil de hoje, com alarme quando um elo para.
--   1. pulso_batimentos (um por fluxo do n8n; escrito só pelo pulso_coleta) e pulso_incidentes (abre/fecha quando um elo muda de nível).
--   2. config_regras pulso_* (limites; nada fixo no código — regra 15) e pulso_modulos (Mari/Meta desligados = o elo some).
--   3. pulso_operacao(): uma chamada, só números (nenhum nome, telefone ou CPF). Traz também "selos" = o retorno do status_operacao.
--   4. status_operacao() vira leitura do pulso_operacao (uma fonte só) e deixa de mostrar data futura: a "última resposta da Mari"
--      sai de mari_conversas.ultima_msg_mari_at sem canal teste e nunca maior que now() (12/11 10h19 mostrava 14/11 15:16).
--   5. RPCs só service_role: pulso_fluxos() · pulso_bater() · pulso_bater_lote() · pulso_registrar(). Logado: pulso_incidente_visto().
-- Observação do n8n: só mari_principal, mari_cadencia e balanco_diario guardam a execução que deu certo; os outros guardam só erro.
-- Para esses, o batimento é "ligado + sem erro recente" (salva_ok = false) e o atraso não é medido — nenhum workflow existente foi mexido.

-- ============================== tabelas ==============================
create table if not exists public.pulso_batimentos (
  parceiro_id            text not null default 'dharma',
  fluxo                  text not null,
  workflow_id            text,
  descricao              text,
  roda                   text,                        -- texto da tela ("a cada 5 min", "a cada mensagem")
  critico                boolean not null default false,
  intervalo_esperado_min int,                         -- nulo = por evento (sem atraso medido)
  janela_inicio          time,                        -- quando deve rodar (nulo = o dia todo)
  janela_fim             time,
  dias_semana            int[],                       -- ISO: 1 seg … 7 dom (nulo = todos)
  ultimo_em              timestamptz,                 -- última execução vista (ok ou erro)
  ultimo_ok_em           timestamptz,
  ultimo_erro_em         timestamptz,
  ultimo_erro            text,
  workflow_ativo         boolean,                     -- lido na API do n8n
  salva_ok               boolean,                     -- o workflow guarda execução com sucesso? (senão só erro é visível)
  lido_em                timestamptz,                 -- última vez que o pulso_coleta leu este fluxo
  ativo                  boolean not null default true,
  primary key (parceiro_id, fluxo)
);
alter table public.pulso_batimentos enable row level security;
drop policy if exists pulso_batimentos_ler on public.pulso_batimentos;
create policy pulso_batimentos_ler on public.pulso_batimentos for select to authenticated using ((select auth.uid()) is not null);
revoke all on public.pulso_batimentos from anon, authenticated;
grant select on public.pulso_batimentos to authenticated;

create table if not exists public.pulso_incidentes (
  id                      bigserial primary key,
  parceiro_id             text not null default 'dharma',
  elo                     text not null check (elo in ('meta', 'entrada', 'mari', 'fluxos')),
  nivel                   text not null check (nivel in ('atencao', 'parado', 'sem_leitura')),
  motivo                  text,
  inicio_em               timestamptz not null default now(),
  fim_em                  timestamptz,
  clientes_esperando_max  int not null default 0,
  visto_em                timestamptz,
  visto_por               uuid
);
create unique index if not exists pulso_incidentes_aberto_uq on public.pulso_incidentes (parceiro_id, elo) where fim_em is null;
create index if not exists pulso_incidentes_inicio_idx on public.pulso_incidentes (inicio_em desc);
alter table public.pulso_incidentes enable row level security;
drop policy if exists pulso_incidentes_ler on public.pulso_incidentes;
create policy pulso_incidentes_ler on public.pulso_incidentes for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke all on public.pulso_incidentes from anon, authenticated;
grant select on public.pulso_incidentes to authenticated;

-- ============================== config ==============================
insert into public.config_regras (chave, valor, descricao, parceiro_id) values
  ('pulso_mari_espera_amarelo_min', '2', 'Pulso: cliente esperando a Mari há N min = atenção', 'dharma'),
  ('pulso_mari_espera_vermelho_min', '5', 'Pulso: cliente esperando a Mari há N min = parado', 'dharma'),
  ('pulso_mari_erros_seguidos', '3', 'Pulso: N erros da Mari sem resposta no meio = parado', 'dharma'),
  ('pulso_meta_coleta_atraso_min', '30', 'Pulso: coleta do Meta sem rodar há N min = atenção (2 h = sem leitura)', 'dharma'),
  ('pulso_entrada_dias_base', '7', 'Pulso: dias para o custo médio por conversa da Meta', 'dharma'),
  ('pulso_entrada_esperado_min', '2', 'Pulso: só julga a entrada quando o gasto de hoje prevê ao menos N conversas', 'dharma'),
  ('pulso_entrada_fator_amarelo', '0.5', 'Pulso: chegou menos que fator × esperado = atenção', 'dharma'),
  ('pulso_fluxo_atraso_fator', '2', 'Pulso: fluxo sem rodar há fator × intervalo (dentro da janela) = atenção', 'dharma'),
  ('pulso_modulos', '{"mari": true, "meta": true}', 'Pulso: módulos ligados; desligado = o elo some da faixa (regra 15)', 'dharma')
on conflict (chave) do nothing;

-- Fluxos da Nio (ids do INFRA §6; o pulso_coleta lê a API do n8n SÓ destes ids — nada da Vero).
insert into public.pulso_batimentos (fluxo, workflow_id, descricao, roda, critico, intervalo_esperado_min, janela_inicio, janela_fim, dias_semana) values
  ('mari_principal',        'Nsb1dcL3HWQpKSav', 'responde o cliente no WhatsApp',             'a cada mensagem',       true,  null, null, null, null),
  ('backoffice_chatwoot',   'aXTo5Q2djsDQbHD5', 'executa no Chatwoot o que você aperta na Live', 'a cada 1 min',       true,  1,    null, null, null),
  ('mari_cadencia',         'efPnlQ1P4UoiNcFG', 'cutucadas e retomadas da Mari',               'a cada 5 min',         false, 5,    null, null, null),
  ('mari_credito',          'JeIRcsCPwhRwT4To', 'consulta de crédito pela Mari',               'a cada 1 min, 7h–23h', false, 1,    '07:00', '23:59', null),
  ('mari_viabilidade',      'lWflylWRGEeT01ys', 'viabilidade do portal para a Mari',           'a cada 2 min, 7h–23h', false, 2,    '07:00', '23:59', null),
  ('mari_duplicidade',      'PW1VsIGHdnJq58Uu', 'pedido Nio em aberto no CPF',                 'a cada 2 min, 7h–23h', false, 2,    '07:00', '23:59', null),
  ('meta_ads_coleta',       'YtpDXBBkIkZQXWt2', 'traz gasto, cliques e saldo da Meta',         'a cada 15 min',        false, 15,   null, null, null),
  ('meta_referral_entrada', 'wilh1NtdO23LWxKt', 'marca a conversa que veio do anúncio',        'a cada conversa nova', false, null, null, null, null),
  ('balanco_diario',        'NccHEIoAKrOPxcUm', 'balanço das conversas paradas',               '7h45, seg–sáb',        false, 1440, '07:45', '23:59', '{1,2,3,4,5,6}'),
  ('auditoria_mari',        'e8og9i9fRjXZKDiG', 'auditoria das conversas da Mari',             '7h30 seg–sáb e a pedido', false, null, null, null, null),
  ('pulso_coleta',          null,               'lê o batimento de todos os outros',           'a cada 5 min',         true,  5,    null, null, null)
on conflict (parceiro_id, fluxo) do nothing;

-- ============================== helpers ==============================
create or replace function public._pulso_cfg(p_chave text, p_padrao numeric)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce((select (valor #>> '{}')::numeric from public.config_regras where chave = p_chave), p_padrao)
$$;
revoke all on function public._pulso_cfg(text, numeric) from public, anon, authenticated;

create or replace function public._pulso_hm(p timestamptz)
returns text language sql stable as $$ select to_char(p at time zone 'America/Sao_Paulo', 'HH24:MI') $$;

-- Quanto tempo, em texto curto ("agora", "há 4 min", "há 2 h", "há 3 d").
create or replace function public._pulso_ha(p timestamptz)
returns text language sql stable as $$
  select case when p is null then null
              when now() - p < interval '1 minute' then 'agora'
              when now() - p < interval '60 minutes' then 'há ' || floor(extract(epoch from now() - p) / 60)::int || ' min'
              when now() - p < interval '48 hours' then 'há ' || floor(extract(epoch from now() - p) / 3600)::int || ' h'
              else 'há ' || floor(extract(epoch from now() - p) / 86400)::int || ' d' end
$$;

-- Último "sem crédito" da API do Claude ainda não resolvido (0135 + 0136, agora num lugar só).
create or replace function public._pulso_mari_sem_credito()
returns timestamptz language plpgsql stable security definer set search_path = public as $$
declare v timestamptz;
begin
  select max(created_at) into v from public.mari_erros
   where created_at > now() - interval '6 hours' and (mensagem ilike '%credit balance%' or mensagem ilike '%billing%');
  select greatest(v, (select max(coalesce(a.fim, a.pedido_em)) from public.auditoria_mari a
                       where a.erro ilike '%credit balance%' and coalesce(a.fim, a.pedido_em) > now() - interval '6 hours'),
                     (select max(b.criado_em) from public.balanco_diario b
                       where b.erro ilike '%credit balance%' and b.criado_em > now() - interval '6 hours'))
    into v;
  if v is not null and exists (select 1 from public.mari_turnos t where t.papel = 'mari' and t.modelo like 'claude%'
                                and t.created_at > v and t.created_at <= now() and t.texto not ilike 'Tive uma instabilidade%') then
    v := null;
  end if;
  return v;
end $$;
revoke all on function public._pulso_mari_sem_credito() from public, anon, authenticated;

-- ============================== pulso_operacao ==============================
create or replace function public.pulso_operacao()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  ORD constant jsonb := '{"ok":0,"sem_leitura":1,"atencao":2,"parado":3}';
  ROT constant jsonb := '{"meta":"Meta Ads","entrada":"Entrada","mari":"Mari","fluxos":"Fluxos n8n"}';
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_ini timestamptz := (v_hoje::timestamp at time zone 'America/Sao_Paulo');
  v_ini_ontem timestamptz := ((v_hoje - 1)::timestamp at time zone 'America/Sao_Paulo');
  v_hora int := extract(hour from now() at time zone 'America/Sao_Paulo')::int;
  v_mod jsonb := coalesce((select valor from public.config_regras where chave = 'pulso_modulos'), '{"mari":true,"meta":true}');
  v_tels text[] := (select array_remove(regexp_split_to_array(regexp_replace(coalesce(texto, ''), '[^0-9,]', '', 'g'), ','), '')
                      from public.config_mari_textos where chave = 'telefones_teste');
  elos jsonb := '{}'; fluxos jsonb := '[]';
  -- Meta
  a_nivel text := 'ok'; a_rot text := 'no ar'; a_mot text[] := '{}'; a_linhas text[] := '{}'; a_texto text;
  v_ativas int; v_ads_ativos int; v_cobranca int; v_reprov int; v_problema int; v_coleta timestamptz; v_conta record;
  v_gasto numeric; v_impr int; v_cliques int; v_meta_err int;
  -- Entrada
  e_nivel text := 'ok'; e_rot text := 'no ritmo'; e_linhas text[] := '{}';
  v_meta_hoje int; v_dir_hoje int; v_ult_nova timestamptz; v_custo numeric; v_esperado numeric;
  -- Mari
  m_nivel text := 'ok'; m_rot text := 'respondendo'; m_mot text[] := '{}'; m_linhas text[] := '{}'; m_texto text;
  v_credito timestamptz; v_claude int; v_claude_ult text; v_infra int; v_esperando int; v_espera_max int; v_alarme timestamptz;
  v_ult_resp timestamptz; v_bal_erro text; v_err_hoje int; v_err_ult timestamptz; v_seguidos int; v_desde timestamptz;
  -- Fluxos
  f_nivel text := 'ok'; f_rot text := 'no horário'; f_linhas text[] := '{}'; f record; f_est text; f_sinal text; f_ok int := 0; f_n int := 0;
  f_err int := 0; f_atr int := 0; f_ult timestamptz; v_coleta_pulso timestamptz; v_sem_leitura boolean; v_na_janela boolean;
  v_dev_hoje timestamptz; v_bo_presa int;
  -- Funil
  fh record; fo record;
  -- Geral
  g_nivel text := 'ok'; g_elo text; g_titulo text; g_desde timestamptz; al_texto text; al_acao text; al_n int := 0; k text;
  m_sel text; a_sel text;
begin
  if public.meu_perfil() is null and auth.role() is distinct from 'service_role' then
    raise exception 'pulso_operacao: sem perfil' using errcode = '42501';
  end if;

  -- ======================= Meta Ads =======================
  if coalesce((v_mod->>'meta')::boolean, true) then
    select count(distinct campanha_id) filter (where status_efetivo = 'ACTIVE'), count(*) filter (where status_efetivo = 'ACTIVE'),
           count(*) filter (where status_efetivo = 'PENDING_BILLING_INFO'), count(*) filter (where status_efetivo = 'DISAPPROVED'),
           count(*) filter (where status_efetivo = 'WITH_ISSUES'), max(atualizado_em)
      into v_ativas, v_ads_ativos, v_cobranca, v_reprov, v_problema, v_coleta
      from public.meta_ads_anuncios;
    select account_status, disable_reason into v_conta from public.meta_ads_conta_saldo order by coletado_em desc limit 1;
    select coalesce(sum(gasto), 0), coalesce(sum(impressoes), 0), coalesce(sum(cliques), 0), max(atualizado_em)
      into v_gasto, v_impr, v_cliques, f_ult
      from public.meta_ads_diario where dia = v_hoje;
    v_coleta := greatest(v_coleta, f_ult, (select max(coletado_em) from public.meta_ads_conta_saldo));
    select count(*) into v_meta_err from public.mari_erros
     where created_at > now() - interval '60 minutes' and payload->>'workflow' = 'meta_ads_coleta';

    if v_conta.account_status in (3, 8) or v_cobranca > 0 then
      a_nivel := 'parado'; a_rot := 'pagamento'; a_texto := 'Meta: pagamento';
      a_mot := a_mot || 'falha no pagamento da conta de anúncios — campanhas paradas até pagar (BM › Cobrança)';
    elsif v_conta.account_status in (2, 100, 101) then
      a_nivel := 'parado'; a_rot := 'conta bloqueada'; a_texto := 'Meta: conta bloqueada';
      a_mot := a_mot || format('conta de anúncios desativada (status %s, motivo %s) — ver no BM', v_conta.account_status, coalesce(v_conta.disable_reason, 0));
    elsif v_conta.account_status = 9 then
      a_nivel := 'atencao'; a_rot := 'pagamento recusado';
      a_mot := a_mot || 'pagamento recusado: conta em carência, ainda entrega mas vai parar — trocar/pagar no BM › Cobrança';
    elsif v_conta.account_status = 7 then
      a_nivel := 'atencao'; a_mot := a_mot || 'conta em revisão de risco da Meta';
    end if;
    if v_ativas = 0 and a_nivel <> 'parado' then
      a_nivel := 'atencao'; a_rot := 'nada no ar'; a_texto := 'Meta: nada no ar';
      a_mot := a_mot || 'nenhuma campanha com anúncio ativo';
    end if;
    if v_reprov > 0 then
      if a_nivel = 'ok' then a_nivel := 'atencao'; a_rot := 'reprovado'; end if;
      a_mot := a_mot || format('%s anúncio(s) reprovado(s)', v_reprov);
    end if;
    if v_problema > 0 then
      if a_nivel = 'ok' then a_nivel := 'atencao'; a_rot := 'com problema'; end if;
      a_mot := a_mot || format('%s anúncio(s) com problema de entrega', v_problema);
    end if;
    if v_coleta is null or v_coleta < now() - interval '2 hours' then
      if a_nivel in ('ok', 'atencao') then a_nivel := 'sem_leitura'; a_rot := 'sem leitura'; end if;
      a_mot := a_mot || format('coleta do Meta parada desde %s — o status pode estar velho',
                               coalesce(to_char(v_coleta at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), 'sempre'));
    elsif v_coleta < now() - make_interval(mins => public._pulso_cfg('pulso_meta_coleta_atraso_min', 30)::int) then
      if a_nivel = 'ok' then a_nivel := 'atencao'; a_rot := 'coleta atrasada'; end if;
      a_mot := a_mot || format('coleta do Meta atrasada (última às %s)', public._pulso_hm(v_coleta));
    elsif v_meta_err >= 2 then
      if a_nivel = 'ok' then a_nivel := 'atencao'; a_rot := 'coleta com erro'; end if;
      a_mot := a_mot || format('%s erro(s) na coleta do Meta na última hora (token ou permissão?)', v_meta_err);
    end if;
    if v_ativas > 0 and v_impr = 0 and v_hora between 10 and 22 then
      if a_nivel = 'ok' then a_nivel := 'atencao'; a_rot := 'sem entrega'; end if;
      a_mot := a_mot || 'campanha no ar mas sem nenhuma impressão hoje';
    end if;
    a_texto := coalesce(a_texto, format('Meta %s no ar', v_ativas));
    a_linhas := array[format('%s campanha%s no ar · %s impressões · %s cliques', v_ativas, case when v_ativas = 1 then '' else 's' end,
                             replace(to_char(v_impr, 'FM999G999G990'), ',', '.'), v_cliques),
                      'lido ' || coalesce(public._pulso_ha(v_coleta), '—')] || a_mot;
    elos := elos || jsonb_build_object('meta', jsonb_build_object('nivel', a_nivel, 'rotulo', a_rot,
      'principal', 'R$ ' || replace(to_char(v_gasto, 'FM999G990D00'), '.', ',') || ' hoje',
      'linhas', to_jsonb(a_linhas), 'gasto', v_gasto, 'ativas', v_ativas, 'impressoes', v_impr, 'cliques', v_cliques,
      'lido_em', v_coleta, 'href', 'metaads.html'));
    a_mot := a_mot || format('%s campanha(s) e %s anúncio(s) ativos · %s impressões hoje', v_ativas, v_ads_ativos, v_impr);
  end if;

  -- ======================= Entrada (só faz sentido com a Meta ligada) =======================
  select count(*) filter (where c.origem = 'meta_ads'), count(*) filter (where coalesce(c.origem, '') <> 'meta_ads'), max(c.created_at)
    into v_meta_hoje, v_dir_hoje, v_ult_nova
    from public.mari_conversas c
   where c.created_at >= v_ini and c.created_at <= now() and c.canal <> 'teste'
     and not (regexp_replace(coalesce(c.telefone, ''), '\D', '', 'g') = any (coalesce(v_tels, '{}')));
  if coalesce((v_mod->>'meta')::boolean, true) then
    with dias as (select d.dia, sum(d.gasto) g from public.meta_ads_diario d
                   where d.dia between v_hoje - public._pulso_cfg('pulso_entrada_dias_base', 7)::int and v_hoje - 1 group by 1),
         conv as (select count(*) n from public.mari_conversas c
                   where c.origem = 'meta_ads' and c.canal <> 'teste'
                     and c.created_at >= ((v_hoje - public._pulso_cfg('pulso_entrada_dias_base', 7)::int)::timestamp at time zone 'America/Sao_Paulo')
                     and c.created_at < v_ini)
    select case when (select n from conv) > 0 then (select sum(g) from dias) / (select n from conv) end into v_custo;
    v_esperado := case when v_custo > 0 then round(v_gasto / v_custo, 1) end;
    if v_esperado >= public._pulso_cfg('pulso_entrada_esperado_min', 2) * 2 and v_meta_hoje = 0 then
      e_nivel := 'parado'; e_rot := 'nada entrando';
    elsif v_esperado >= public._pulso_cfg('pulso_entrada_esperado_min', 2)
          and v_meta_hoje < v_esperado * public._pulso_cfg('pulso_entrada_fator_amarelo', 0.5) then
      e_nivel := 'atencao'; e_rot := 'abaixo do esperado';
    elsif v_esperado is null or v_esperado < public._pulso_cfg('pulso_entrada_esperado_min', 2) then
      e_rot := case when v_meta_hoje > 0 then 'no ritmo' else 'pouco gasto' end;
    end if;
    e_linhas := array[case when v_esperado is not null then format('pelo gasto, o esperado era %s', replace(round(v_esperado)::text, '.', ','))
                           else 'sem base de custo por conversa' end
                      || case when v_dir_hoje > 0 then format(' · mais %s direta%s', v_dir_hoje, case when v_dir_hoje = 1 then '' else 's' end) else '' end,
                      case when v_ult_nova is not null then format('última conversa nova às %s', public._pulso_hm(v_ult_nova))
                           else 'nenhuma conversa nova hoje' end];
    elos := elos || jsonb_build_object('entrada', jsonb_build_object('nivel', e_nivel, 'rotulo', e_rot,
      'principal', format('%s da Meta', v_meta_hoje), 'linhas', to_jsonb(e_linhas), 'meta_hoje', v_meta_hoje, 'diretas_hoje', v_dir_hoje,
      'esperado', v_esperado, 'custo_conversa', round(v_custo, 2), 'ultima_nova_em', v_ult_nova, 'href', 'conversas.html'));
  end if;

  -- ======================= Mari =======================
  if coalesce((v_mod->>'mari')::boolean, true) then
    v_credito := public._pulso_mari_sem_credito();
    select count(*), max(left(mensagem, 140)) into v_claude, v_claude_ult from public.mari_erros
     where created_at > now() - interval '30 minutes' and (no_n8n like '6%Claude%' or mensagem like 'Claude API:%');
    select count(*) into v_infra from public.mari_erros
     where created_at > now() - interval '60 minutes' and payload ? 'execution_id'
       and coalesce(payload->>'workflow', '') not in ('meta_ads_coleta');
    select count(*), coalesce(max(minutos), 0) into v_esperando, v_espera_max from public.v_mari_sem_resposta;
    select min(avisado_em) into v_alarme from public.mari_alarmes where resolvido_em is null and avisado_em is not null;
    -- 0144: a última resposta real — sem canal teste e nunca no futuro (o selo mostrava 14/11 em 12/11).
    select max(c.ultima_msg_mari_at) into v_ult_resp from public.mari_conversas c
     where c.canal <> 'teste' and c.ultima_msg_mari_at <= now();
    select erro into v_bal_erro from public.balanco_diario where criado_em > now() - interval '24 hours' order by criado_em desc limit 1;
    select count(*), max(created_at) into v_err_hoje, v_err_ult from public.mari_erros
     where created_at >= v_ini and coalesce(payload->>'workflow', '') not in ('meta_ads_coleta');
    select count(*), min(created_at) into v_seguidos, v_desde from public.mari_erros
     where created_at > greatest(coalesce(v_ult_resp, now() - interval '2 hours'), now() - interval '2 hours')
       and coalesce(payload->>'workflow', '') not in ('meta_ads_coleta');

    if v_credito is not null or v_bal_erro ilike '%credit balance%' then
      m_nivel := 'parado'; m_rot := 'sem crédito'; m_texto := 'Mari sem crédito';
      m_mot := m_mot || format('API do Claude sem crédito (último erro %s) — recarregar em console.anthropic.com',
                               to_char(coalesce(v_credito, now()) at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'));
    end if;
    if v_seguidos >= public._pulso_cfg('pulso_mari_erros_seguidos', 3) then
      m_nivel := 'parado'; m_rot := coalesce(nullif(m_rot, 'respondendo'), 'falhando'); m_texto := coalesce(m_texto, 'Mari falhando');
      m_mot := m_mot || format('%s erros seguidos desde %s', v_seguidos, public._pulso_hm(v_desde));
    end if;
    if v_claude >= 2 then
      m_nivel := 'parado'; m_rot := coalesce(nullif(m_rot, 'respondendo'), 'falhando'); m_texto := coalesce(m_texto, 'Mari falhando');
      m_mot := m_mot || format('%s falha(s) da API do Claude em 30 min: %s', v_claude, v_claude_ult);
    elsif v_claude = 1 then
      if m_nivel = 'ok' then m_nivel := 'atencao'; m_rot := '1 falha'; end if;
      m_mot := m_mot || format('1 falha da API do Claude em 30 min: %s', v_claude_ult);
    end if;
    if v_esperando > 0 then
      if v_espera_max >= public._pulso_cfg('pulso_mari_espera_vermelho_min', 5) then
        m_nivel := 'parado'; m_rot := coalesce(nullif(m_rot, 'respondendo'), 'parada'); m_texto := coalesce(m_texto, 'Mari parada');
      elsif v_espera_max >= public._pulso_cfg('pulso_mari_espera_amarelo_min', 2) and m_nivel = 'ok' then
        m_nivel := 'atencao'; m_rot := 'demorando';
      end if;
      m_mot := m_mot || format('%s cliente(s) esperando resposta da Mari (o mais antigo há %s min)', v_esperando, v_espera_max);
    elsif v_alarme is not null then
      m_nivel := 'parado'; m_rot := coalesce(nullif(m_rot, 'respondendo'), 'parada'); m_texto := coalesce(m_texto, 'Mari parada');
      m_mot := m_mot || format('alarme de silêncio aberto desde %s', public._pulso_hm(v_alarme));
    end if;
    if v_infra >= 3 then
      if m_nivel = 'ok' then m_nivel := 'atencao'; m_rot := 'erros de fluxo'; end if;
      m_mot := m_mot || format('%s erro(s) de fluxo no n8n na última hora (ver Mari › Erros)', v_infra);
    elsif v_infra > 0 then
      m_mot := m_mot || format('%s erro(s) isolado(s) de fluxo na última hora', v_infra);
    end if;
    if v_bal_erro is not null and v_bal_erro not ilike '%credit balance%' then
      if m_nivel = 'ok' then m_nivel := 'atencao'; m_rot := 'balanço falhou'; end if;
      m_mot := m_mot || format('balanço diário falhou: %s', left(v_bal_erro, 120));
    end if;
    m_texto := coalesce(m_texto, case m_nivel when 'ok' then 'Mari ok' else 'Mari com alerta' end);
    if v_ult_resp is not null then
      m_mot := m_mot || format('última resposta da Mari: %s', to_char(v_ult_resp at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'));
    end if;
    m_linhas := array[case when v_esperando = 0 then 'ninguém esperando resposta'
                           else format('%s cliente%s esperando resposta', v_esperando, case when v_esperando = 1 then '' else 's' end) end,
                      case when v_seguidos >= public._pulso_cfg('pulso_mari_erros_seguidos', 3)
                             then format('%s erros seguidos desde %s', v_seguidos, public._pulso_hm(v_desde))
                           when v_err_hoje > 0 then format('%s erro%s hoje, o último às %s', v_err_hoje, case when v_err_hoje = 1 then '' else 's' end, public._pulso_hm(v_err_ult))
                           else 'nenhum erro hoje' end];
    elos := elos || jsonb_build_object('mari', jsonb_build_object('nivel', m_nivel, 'rotulo', m_rot,
      'principal', coalesce(public._pulso_ha(v_ult_resp), 'sem resposta'), 'linhas', to_jsonb(m_linhas),
      'ultima_resposta_em', v_ult_resp, 'esperando', v_esperando, 'espera_max_min', v_espera_max, 'erros_hoje', v_err_hoje,
      'erros_seguidos', v_seguidos, 'motivos', to_jsonb(m_mot), 'href', 'mari.html'));
  end if;

  -- ======================= Fluxos n8n =======================
  select lido_em into v_coleta_pulso from public.pulso_batimentos where parceiro_id = 'dharma' and fluxo = 'pulso_coleta';
  v_sem_leitura := v_coleta_pulso is null or v_coleta_pulso < now() - interval '15 minutes';
  select count(*) into v_bo_presa from public.chatwoot_acoes
   where status = 'pendente' and executar_apos < now() - interval '5 minutes';
  for f in select * from public.pulso_batimentos b where b.parceiro_id = 'dharma' and b.ativo
            and (coalesce((v_mod->>'mari')::boolean, true) or b.fluxo not like 'mari%')
            and (coalesce((v_mod->>'meta')::boolean, true) or b.fluxo not like 'meta%')
           order by b.critico desc, b.fluxo loop
    f_n := f_n + 1;
    v_na_janela := (f.dias_semana is null or extract(isodow from now() at time zone 'America/Sao_Paulo')::int = any (f.dias_semana))
               and (f.janela_inicio is null or (now() at time zone 'America/Sao_Paulo')::time >= f.janela_inicio)
               and (f.janela_fim is null or (now() at time zone 'America/Sao_Paulo')::time <= f.janela_fim);
    f_est := 'ok'; f_sinal := 'ok';
    if f.fluxo = 'pulso_coleta' then
      if v_coleta_pulso is null then f_est := 'a_ligar'; f_sinal := 'a ligar';
      elsif v_sem_leitura then f_est := 'parado'; f_sinal := 'parado — o pulso não está lendo os fluxos'; end if;
    elsif v_sem_leitura then
      f_est := case when v_coleta_pulso is null then 'a_ligar' else 'sem_leitura' end;
      f_sinal := case when v_coleta_pulso is null then 'a ligar' else 'sem leitura' end;
    elsif f.workflow_ativo is false then
      f_est := case when f.critico then 'parado' else 'atencao' end; f_sinal := 'desligado no n8n';
    elsif f.lido_em is null then
      f_est := 'a_ligar'; f_sinal := 'a ligar';
    elsif f.ultimo_erro_em is not null
          and ((f.salva_ok and f.ultimo_erro_em > coalesce(f.ultimo_ok_em, '-infinity'))
               or (not coalesce(f.salva_ok, false)
                   and f.ultimo_erro_em > now() - greatest(interval '15 minutes', make_interval(mins => coalesce(f.intervalo_esperado_min, 0) * 2))))
    then
      f_est := case when f.critico then 'parado' else 'atencao' end;
      f_sinal := format('erro às %s', public._pulso_hm(f.ultimo_erro_em));
    elsif f.salva_ok and f.intervalo_esperado_min is not null and v_na_janela then
      if f.intervalo_esperado_min >= 1440 then
        -- diário: já devia ter rodado hoje (meia hora de folga depois do início da janela)
        v_dev_hoje := (v_hoje + f.janela_inicio)::timestamp at time zone 'America/Sao_Paulo';
        if now() > v_dev_hoje + interval '30 minutes' and coalesce(f.ultimo_ok_em, '-infinity') < v_dev_hoje then
          f_est := 'atencao'; f_sinal := 'não rodou hoje';
        end if;
      elsif coalesce(f.ultimo_ok_em, '-infinity') < now() - make_interval(mins => (f.intervalo_esperado_min * public._pulso_cfg('pulso_fluxo_atraso_fator', 2))::int)
            and (f.janela_inicio is null or (now() at time zone 'America/Sao_Paulo')::time
                   >= f.janela_inicio + make_interval(mins => (f.intervalo_esperado_min * public._pulso_cfg('pulso_fluxo_atraso_fator', 2))::int)) then
        f_est := case when f.critico and coalesce(f.ultimo_ok_em, '-infinity') < now() - make_interval(mins => f.intervalo_esperado_min * 6)
                      then 'parado' else 'atencao' end;
        f_sinal := 'atrasado';
      end if;
    end if;
    if f.fluxo = 'backoffice_chatwoot' and f_est in ('ok') and v_bo_presa > 0 then
      f_est := 'atencao'; f_sinal := format('%s ação(ões) da Live esperando há mais de 5 min', v_bo_presa);
    end if;
    if f_est = 'ok' then f_ok := f_ok + 1; end if;
    if f_est in ('parado', 'atencao') and f_sinal like 'erro%' then f_err := f_err + 1; end if;
    if f_est in ('parado', 'atencao') and f_sinal not like 'erro%' then f_atr := f_atr + 1; end if;
    if (ORD->>(case when f_est = 'a_ligar' then 'ok' else f_est end))::int > (ORD->>f_nivel)::int then f_nivel := f_est; end if;
    fluxos := fluxos || jsonb_build_object('fluxo', f.fluxo, 'descricao', f.descricao, 'roda', f.roda, 'critico', f.critico,
      'estado', f_est, 'sinal', f_sinal, 'salva_ok', f.salva_ok, 'ativo_n8n', f.workflow_ativo,
      'ultimo_ok_em', f.ultimo_ok_em, 'ultimo_erro_em', f.ultimo_erro_em,
      'ultimo_erro', case when f.ultimo_erro_em > now() - interval '24 hours' then left(f.ultimo_erro, 160) end, 'lido_em', f.lido_em);
  end loop;
  if f_n > 0 then
    f_rot := case when v_sem_leitura and v_coleta_pulso is null then 'a ligar'
                  when v_sem_leitura then 'sem leitura'
                  when f_err > 0 then format('%s com erro', f_err)
                  when f_atr > 0 then format('%s atrasado%s', f_atr, case when f_atr = 1 then '' else 's' end)
                  else 'no horário' end;
    if v_sem_leitura and v_coleta_pulso is null then f_nivel := 'ok'; end if;   -- ainda não ligado: não alarma
    elos := elos || jsonb_build_object('fluxos', jsonb_build_object('nivel', f_nivel, 'rotulo', f_rot,
      'principal', case when v_coleta_pulso is null then 'a ligar' when f_nivel = 'ok' then public._pulso_ha(v_coleta_pulso)
                        else format('%s de %s', f_ok, f_n) end,
      'linhas', to_jsonb(array[
        coalesce((select format('%s: %s', x->>'fluxo', x->>'sinal') from jsonb_array_elements(fluxos) x
                   where x->>'estado' in ('parado', 'atencao', 'sem_leitura') order by (ORD->>(x->>'estado'))::int desc limit 1),
                 case when v_coleta_pulso is null then 'ainda sem batimento'
                      else format('%s fluxos lidos às %s', f_n, public._pulso_hm(v_coleta_pulso)) end),
        case when v_coleta_pulso is null then 'o pulso_coleta lê o n8n a cada 5 min' when f_nivel = 'ok' then 'todos no horário' else format('%s de %s no horário', f_ok, f_n) end]),
      'lido_em', v_coleta_pulso, 'href', null));
  end if;

  -- ======================= Funil de hoje × ontem =======================
  select count(*) filter (where c.created_at >= v_ini) conversas,
         count(*) filter (where c.handoff_motivo = 'dados_completos' and c.handoff_em >= v_ini) qualificadas,
         count(*) filter (where c.created_at >= v_ini_ontem and c.created_at < v_ini) conversas_o,
         count(*) filter (where c.handoff_motivo = 'dados_completos' and c.handoff_em >= v_ini_ontem and c.handoff_em < v_ini) qualificadas_o
    into fh
    from public.mari_conversas c
   where c.canal <> 'teste' and (c.created_at >= v_ini_ontem or c.handoff_em >= v_ini_ontem)
     and not (regexp_replace(coalesce(c.telefone, ''), '\D', '', 'g') = any (coalesce(v_tels, '{}')));
  select count(*) filter (where v.vendido_em >= v_ini) hoje, count(*) filter (where v.vendido_em >= v_ini_ontem and v.vendido_em < v_ini) ontem
    into fo from public.vendas v where v.vendido_em >= v_ini_ontem;

  -- ======================= Geral + alerta =======================
  for k in select x from unnest(array['meta', 'entrada', 'mari', 'fluxos']) x loop
    if elos ? k and (ORD->>(elos->k->>'nivel'))::int > (ORD->>g_nivel)::int then g_nivel := elos->k->>'nivel'; g_elo := k; end if;
  end loop;
  g_titulo := case g_nivel when 'ok' then 'Tudo respirando'
                           when 'parado' then format('%s %s', ROT->>g_elo, case when g_elo in ('mari', 'entrada') then 'parada' else 'parado' end)
                           when 'atencao' then format('%s em atenção', ROT->>g_elo)
                           else format('%s sem leitura', ROT->>g_elo) end;
  if g_elo is not null then
    select inicio_em into g_desde from public.pulso_incidentes where parceiro_id = 'dharma' and elo = g_elo and fim_em is null;
  end if;
  if g_elo = 'mari' then
    al_texto := case when (elos->'meta'->>'nivel') = 'ok' and v_meta_hoje > 0 then 'Os anúncios estão entregando e os clientes estão escrevendo, mas '
                     when v_meta_hoje + v_dir_hoje > 0 then 'Os clientes estão escrevendo, mas ' else '' end
             || case when m_rot = 'sem crédito' then 'a Mari está sem crédito na API do Claude'
                     when v_ult_resp is not null then format('a Mari não responde desde %s', public._pulso_hm(v_ult_resp))
                     else 'a Mari não está respondendo' end
             || case when v_esperando > 0 then format('. %s cliente%s esperando.', v_esperando, case when v_esperando = 1 then '' else 's' end) else '.' end;
    al_acao := case when v_esperando > 0 then 'esperando' else 'erro' end; al_n := v_esperando;
  elsif g_elo = 'entrada' then
    al_texto := format('A Meta gastou R$ %s hoje e %s', replace(to_char(v_gasto, 'FM999G990D00'), '.', ','),
                       case when v_meta_hoje = 0 then 'nenhuma conversa do anúncio entrou — suspeita de webhook ou WhatsApp.'
                            else format('só %s conversa%s do anúncio entrou (esperado %s).', v_meta_hoje, case when v_meta_hoje = 1 then '' else 's' end, round(v_esperado)) end);
    al_acao := 'erro';
  elsif g_elo = 'meta' then
    al_texto := 'Anúncios: ' || coalesce(a_mot[1], a_rot) || '.'; al_acao := 'meta';
  elsif g_elo = 'fluxos' then
    al_texto := 'Fluxo do n8n: ' || (elos->'fluxos'->'linhas'->>0) || '.'; al_acao := 'erro';
  end if;

  -- Selos do menu (o antigo retorno do status_operacao): uma fonte só.
  m_sel := case coalesce(elos->'mari'->>'nivel', 'ok') when 'parado' then 'falha' when 'ok' then 'ok' else 'alerta' end;
  a_sel := case coalesce(elos->'meta'->>'nivel', 'ok') when 'parado' then 'falha' when 'ok' then 'ok' else 'alerta' end;

  return jsonb_build_object(
    'gerado_em', now(),
    'geral', jsonb_build_object('nivel', g_nivel, 'elo', g_elo, 'titulo', g_titulo, 'desde', g_desde),
    'elos', elos,
    'funil', jsonb_build_object('hoje', jsonb_build_object('conversas', fh.conversas, 'qualificadas', fh.qualificadas, 'vendas', fo.hoje),
                                'ontem', jsonb_build_object('conversas', fh.conversas_o, 'qualificadas', fh.qualificadas_o, 'vendas', fo.ontem)),
    'alerta', case when al_texto is not null then jsonb_build_object('texto', al_texto, 'acao', al_acao, 'n', al_n, 'elo', g_elo, 'nivel', g_nivel) end,
    'fluxos', fluxos,
    'selos', jsonb_build_object('agora', now(),
      'mari', case when elos ? 'mari' then jsonb_build_object('nivel', m_sel, 'texto', m_texto, 'motivos', to_jsonb(m_mot), 'href', 'mari.html') end,
      'meta', case when elos ? 'meta' then jsonb_build_object('nivel', a_sel, 'texto', a_texto, 'motivos', to_jsonb(a_mot), 'href', 'metaads.html') end));
end $$;
revoke all on function public.pulso_operacao() from public, anon;
grant execute on function public.pulso_operacao() to authenticated, service_role;

-- O selo do menu passa a sair do pulso (uma regra só). Mesmo formato de antes: {agora, mari, meta}.
create or replace function public.status_operacao()
returns jsonb language sql stable security definer set search_path = public as $$
  select public.pulso_operacao()->'selos'
$$;
revoke all on function public.status_operacao() from public, anon;
grant execute on function public.status_operacao() to authenticated, service_role;

-- ============================== escrita (só service_role) ==============================
create or replace function public.pulso_fluxos()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('fluxo', fluxo, 'workflow_id', workflow_id) order by fluxo), '[]')
    from public.pulso_batimentos where parceiro_id = 'dharma' and ativo and workflow_id is not null
$$;
revoke all on function public.pulso_fluxos() from public, anon, authenticated;
grant execute on function public.pulso_fluxos() to service_role;

-- p_ok: true = a última execução vista deu certo · false = deu erro · null = nenhuma execução guardada.
create or replace function public.pulso_bater(p_fluxo text, p_ok boolean, p_erro text, p_em timestamptz,
                                              p_ativo boolean default null, p_salva_ok boolean default null,
                                              p_ultimo_ok_em timestamptz default null, p_ultimo_erro_em timestamptz default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.pulso_batimentos set
    ultimo_em      = greatest(ultimo_em, p_em, p_ultimo_ok_em, p_ultimo_erro_em),
    ultimo_ok_em   = greatest(ultimo_ok_em, case when p_ok then p_em end, p_ultimo_ok_em),
    ultimo_erro_em = greatest(ultimo_erro_em, case when p_ok is false then p_em end, p_ultimo_erro_em),
    ultimo_erro    = case when coalesce(case when p_ok is false then p_em end, p_ultimo_erro_em) > coalesce(ultimo_erro_em, '-infinity')
                          then left(coalesce(p_erro, 'execução com erro'), 300) else ultimo_erro end,
    workflow_ativo = coalesce(p_ativo, workflow_ativo),
    salva_ok       = coalesce(p_salva_ok, salva_ok),
    lido_em        = now()
  where parceiro_id = 'dharma' and fluxo = p_fluxo;
end $$;
revoke all on function public.pulso_bater(text, boolean, text, timestamptz, boolean, boolean, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.pulso_bater(text, boolean, text, timestamptz, boolean, boolean, timestamptz, timestamptz) to service_role;

-- O pulso_coleta manda tudo numa chamada: [{fluxo, ativo, salva_ok, ok_em, erro_em, erro}]. O detalhe do erro vem do mari_erros
-- (Error Trigger: nó + mensagem) quando houver, senão "execução <id> com erro".
create or replace function public.pulso_bater_lote(p_itens jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i jsonb; n int := 0; v_err text;
begin
  for i in select * from jsonb_array_elements(coalesce(p_itens, '[]')) loop
    v_err := null;
    if nullif(i->>'erro_em', '') is not null then
      select coalesce(no_n8n || ': ', '') || left(mensagem, 200) into v_err from public.mari_erros
       where payload->>'execution_id' = i->>'erro_id' order by id desc limit 1;
    end if;
    perform public.pulso_bater(i->>'fluxo', null, coalesce(v_err, i->>'erro'), null,
                               (i->>'ativo')::boolean, (i->>'salva_ok')::boolean,
                               nullif(i->>'ok_em', '')::timestamptz, nullif(i->>'erro_em', '')::timestamptz);
    n := n + 1;
  end loop;
  perform public.pulso_bater('pulso_coleta', true, null, now(), true, false, now(), null);
  return jsonb_build_object('ok', true, 'fluxos', n);
end $$;
revoke all on function public.pulso_bater_lote(jsonb) from public, anon, authenticated;
grant execute on function public.pulso_bater_lote(jsonb) to service_role;

-- Abre/fecha incidente quando o nível de um elo muda. Devolve os incidentes "parado" abertos agora (para um aviso futuro).
create or replace function public.pulso_registrar()
returns jsonb language plpgsql security definer set search_path = public as $$
declare p jsonb := public.pulso_operacao(); k text; e jsonb; a record; abertos jsonb := '[]'; v_esp int;
begin
  for k in select x from unnest(array['meta', 'entrada', 'mari', 'fluxos']) x loop
    e := p->'elos'->k;
    select * into a from public.pulso_incidentes where parceiro_id = 'dharma' and elo = k and fim_em is null;
    v_esp := coalesce((e->>'esperando')::int, 0);
    if e is null or e->>'nivel' = 'ok' then
      if a.id is not null then update public.pulso_incidentes set fim_em = now() where id = a.id; end if;
    elsif a.id is not null and a.nivel = e->>'nivel' then
      update public.pulso_incidentes set clientes_esperando_max = greatest(clientes_esperando_max, v_esp) where id = a.id;
    else
      if a.id is not null then update public.pulso_incidentes set fim_em = now() where id = a.id; end if;
      insert into public.pulso_incidentes (elo, nivel, motivo, clientes_esperando_max)
      values (k, e->>'nivel', left(coalesce(e->>'rotulo', '') || ' — ' || coalesce(e->'linhas'->>0, ''), 300), v_esp);
      if e->>'nivel' = 'parado' then abertos := abertos || jsonb_build_object('elo', k, 'motivo', e->>'rotulo'); end if;
    end if;
  end loop;
  return jsonb_build_object('geral', p->'geral', 'novos_parados', abertos);
end $$;
revoke all on function public.pulso_registrar() from public, anon, authenticated;
grant execute on function public.pulso_registrar() to service_role;

-- "Alguém viu": o 1º clique no alerta da faixa marca os incidentes abertos (mede minutos até alguém agir).
create or replace function public.pulso_incidente_visto()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if coalesce((select public.meu_perfil()), '') not in ('admin', 'backoffice') then return 0; end if;
  update public.pulso_incidentes set visto_em = now(), visto_por = (select auth.uid())
   where parceiro_id = 'dharma' and fim_em is null and visto_em is null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.pulso_incidente_visto() from public, anon;
grant execute on function public.pulso_incidente_visto() to authenticated;
