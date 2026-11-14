-- NIOGEN | 0187_pulso_meta_sem_anuncio_nao_derruba.sql | 13/11/2026
-- Defeito antigo (desde a 0144): no elo Meta, a_mot é text[] e `a_mot || 'texto'` faz o Postgres ler o literal
-- como array -> "malformed array literal". Toda vez que a Meta entra num desses estados (nada no ar, sem impressão,
-- pagamento recusado/carência, revisão de risco), a pulso_operacao quebra, o pulso_registrar devolve 400 e o pulso
-- inteiro deixa de ser gravado. Visto em 13/11 20:45-20:55 (Meta sem anúncio ativo): 3 erros do pulso_coleta.
-- Correção: só `::text` nos 5 literais. Resto da função idêntico ao que estava no ar (pg_get_functiondef).
CREATE OR REPLACE FUNCTION public.pulso_operacao()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- 0169: fluxos de ensaio (bateria de testes da Mari) — o erro deles não é erro da operação.
  v_ensaio text[] := coalesce((select array(select jsonb_array_elements_text(valor)) from public.config_regras
                                where chave = 'pulso_fluxos_ensaio' and jsonb_typeof(valor) = 'array'), '{}');
  -- 0170: erro de conexão do n8n com o banco tem nome próprio no alerta. 0183: quem diz o que é conexão é mari_erros.classe.
  -- 0183: vermelho da Mari só com cliente esperando (config_regras.pulso_mari_parado_exige_espera; false = volta ao que era).
  v_exige boolean := coalesce((select (valor #>> '{}')::boolean from public.config_regras where chave = 'pulso_mari_parado_exige_espera'), true);
  v_outros int := 0; v_gov int := 0; v_av_txt text; v_ult_conv timestamptz;
  v_conex int := 0; v_conex_de timestamptz; v_conex_ate timestamptz; v_conex_fluxos int := 0; v_so_conexao boolean := false; v_cx_txt text;
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
      a_mot := a_mot || 'falha no pagamento da conta de anúncios — campanhas paradas até pagar (BM › Cobrança)'::text;
    elsif v_conta.account_status in (2, 100, 101) then
      a_nivel := 'parado'; a_rot := 'conta bloqueada'; a_texto := 'Meta: conta bloqueada';
      a_mot := a_mot || format('conta de anúncios desativada (status %s, motivo %s) — ver no BM', v_conta.account_status, coalesce(v_conta.disable_reason, 0));
    elsif v_conta.account_status = 9 then
      a_nivel := 'atencao'; a_rot := 'pagamento recusado';
      a_mot := a_mot || 'pagamento recusado: conta em carência, ainda entrega mas vai parar — trocar/pagar no BM › Cobrança'::text;
    elsif v_conta.account_status = 7 then
      a_nivel := 'atencao'; a_mot := a_mot || 'conta em revisão de risco da Meta'::text;
    end if;
    if v_ativas = 0 and a_nivel <> 'parado' then
      a_nivel := 'atencao'; a_rot := 'nada no ar'; a_texto := 'Meta: nada no ar';
      a_mot := a_mot || 'nenhuma campanha com anúncio ativo'::text;
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
      a_mot := a_mot || 'campanha no ar mas sem nenhuma impressão hoje'::text;
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
     where created_at > now() - interval '30 minutes' and (no_n8n like '6%Claude%' or mensagem like 'Claude API:%')
       and coalesce(payload->>'workflow', '') <> all (v_ensaio);
    select count(*) into v_infra from public.mari_erros
     where created_at > now() - interval '60 minutes' and payload ? 'execution_id'
       and classe in ('mari', 'conexao')   -- 0183: erro de outro fluxo e registro de governança saem no elo Fluxos
       and coalesce(payload->>'workflow', '') not in ('meta_ads_coleta')
       and coalesce(payload->>'workflow', '') <> all (v_ensaio);
    select count(*), min(created_at), max(created_at), count(distinct payload->>'workflow')
      into v_conex, v_conex_de, v_conex_ate, v_conex_fluxos from public.mari_erros
     where created_at > now() - interval '60 minutes' and payload ? 'execution_id'
       and coalesce(payload->>'workflow', '') not in ('meta_ads_coleta')
       and coalesce(payload->>'workflow', '') <> all (v_ensaio)
       and classe = 'conexao';
    select count(*), coalesce(max(minutos), 0) into v_esperando, v_espera_max from public.v_mari_sem_resposta;
    select min(avisado_em) into v_alarme from public.mari_alarmes where resolvido_em is null and avisado_em is not null;
    -- 0144: a última resposta real — sem canal teste e nunca no futuro (o selo mostrava 14/11 em 12/11).
    select max(c.ultima_msg_mari_at) into v_ult_resp from public.mari_conversas c
     where c.canal <> 'teste' and c.ultima_msg_mari_at <= now();
    select erro into v_bal_erro from public.balanco_diario where criado_em > now() - interval '24 hours' order by criado_em desc limit 1;
    select count(*), max(created_at) into v_err_hoje, v_err_ult from public.mari_erros
     where created_at >= v_ini and classe = 'mari';
    -- 0183: a última conversa nova (qualquer dia) — com ninguém esperando, o elo diz desde quando não entra ninguém.
    select max(c.created_at) into v_ult_conv from public.mari_conversas c
     where c.canal <> 'teste' and c.created_at <= now()
       and not (regexp_replace(coalesce(c.telefone, ''), '\D', '', 'g') = any (coalesce(v_tels, '{}')));
    -- 0162: "erros seguidos" = falhas do caminho de resposta da Mari. 0183: quem diz o que é do caminho de resposta é a classe do
    -- erro (gatilho mari_erros_classe + config_regras.pulso_erros_classes) — registro de governança (resposta_fora_niogen,
    -- jornada_furo), erro de outro fluxo (operador de OS, GED360, cadência…) e queda de conexão não acendem "Mari falhando".
    select count(*), min(created_at) into v_seguidos, v_desde from public.mari_erros
     where created_at > greatest(coalesce(v_ult_resp, now() - interval '2 hours'), now() - interval '2 hours')
       and classe = 'mari';

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
    if v_infra >= 3 and v_conex >= 3 and v_conex * 2 > v_infra then
      -- 0170: a maioria é queda de conexão com o banco — dizer isso, não "Mari".
      v_cx_txt := format('a conexão do n8n com o banco caiu das %s às %s (%s erros em %s fluxo%s)', public._pulso_hm(v_conex_de),
                         public._pulso_hm(v_conex_ate), v_conex, v_conex_fluxos, case when v_conex_fluxos = 1 then '' else 's' end);
      if m_nivel = 'ok' then
        m_nivel := 'atencao'; m_rot := 'conexão com o banco'; m_texto := 'Conexão com o banco caiu'; v_so_conexao := true;
      end if;
      m_mot := m_mot || v_cx_txt;
      if v_infra > v_conex then
        m_mot := m_mot || format('mais %s erro(s) de fluxo no n8n na última hora (ver Mari › Erros)', v_infra - v_conex);
      end if;
    elsif v_infra >= 3 then
      if m_nivel = 'ok' then m_nivel := 'atencao'; m_rot := 'erros de fluxo'; end if;
      m_mot := m_mot || format('%s erro(s) de fluxo no n8n na última hora (ver Mari › Erros)', v_infra);
    elsif v_infra > 0 then
      m_mot := m_mot || format('%s erro(s) isolado(s) de fluxo na última hora', v_infra);
    end if;
    if v_bal_erro is not null and v_bal_erro not ilike '%credit balance%' then
      if m_nivel = 'ok' then m_nivel := 'atencao'; m_rot := 'balanço falhou'; end if;
      m_mot := m_mot || format('balanço diário falhou: %s', left(v_bal_erro, 120));
    end if;
    -- 0183: vermelho só com cliente esperando. Falha sem ninguém esperando fica em atenção (sem crédito continua vermelho:
    -- o próximo cliente não será respondido). Assim que alguém espera, as regras acima acendem o vermelho de novo.
    if v_exige and m_nivel = 'parado' and v_esperando = 0 and m_rot <> 'sem crédito' then
      m_nivel := 'atencao'; m_rot := 'com falhas'; m_texto := 'Mari com falhas';
    end if;
    m_texto := coalesce(m_texto, case m_nivel when 'ok' then 'Mari ok' else 'Mari com alerta' end);
    if v_ult_resp is not null then
      m_mot := m_mot || format('última resposta da Mari: %s', to_char(v_ult_resp at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'));
    end if;
    m_linhas := array[case when v_esperando = 0 and v_ult_conv < now() - interval '30 minutes'
                             then format('ninguém esperando · sem conversa nova desde %s',
                                         case when v_ult_conv >= v_ini then public._pulso_hm(v_ult_conv)
                                              else to_char(v_ult_conv at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') end)
                           when v_esperando = 0 then 'ninguém esperando resposta'
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
  -- 0183: o que caiu em mari_erros e não é da Mari (outro fluxo, governança) aparece aqui, no máximo em atenção.
  select count(*) filter (where classe = 'outro_fluxo'), count(*) filter (where classe = 'governanca') into v_outros, v_gov
    from public.mari_erros
   where created_at > now() - interval '60 minutes'
     and coalesce(payload->>'workflow', '') not in ('meta_ads_coleta')
     and coalesce(payload->>'workflow', '') <> all (v_ensaio);
  v_av_txt := nullif(concat_ws(' · ',
    case when v_outros > 0 then format('%s erro%s de outros fluxos', v_outros, case when v_outros = 1 then '' else 's' end) end,
    case when v_gov > 0 then format('%s aviso%s de governança (Live › Conferir)', v_gov, case when v_gov = 1 then '' else 's' end) end), '');
  if v_av_txt is not null then v_av_txt := v_av_txt || ' na última hora'; end if;
  if f_n > 0 then
    f_rot := case when v_sem_leitura and v_coleta_pulso is null then 'a ligar'
                  when v_sem_leitura then 'sem leitura'
                  when f_err > 0 then format('%s com erro', f_err)
                  when f_atr > 0 then format('%s atrasado%s', f_atr, case when f_atr = 1 then '' else 's' end)
                  else 'no horário' end;
    if v_sem_leitura and v_coleta_pulso is null then f_nivel := 'ok'; end if;   -- ainda não ligado: não alarma
    if v_outros >= 3 and f_nivel = 'ok' and not v_sem_leitura then f_nivel := 'atencao'; f_rot := 'erros de outros fluxos'; end if;
    elos := elos || jsonb_build_object('fluxos', jsonb_build_object('nivel', f_nivel, 'rotulo', f_rot,
      'principal', case when v_coleta_pulso is null then 'a ligar' when f_nivel = 'ok' then public._pulso_ha(v_coleta_pulso)
                        else format('%s de %s', f_ok, f_n) end,
      'linhas', to_jsonb(array[
        coalesce((select format('%s: %s', x->>'fluxo', x->>'sinal') from jsonb_array_elements(fluxos) x
                   where x->>'estado' in ('parado', 'atencao', 'sem_leitura') order by (ORD->>(x->>'estado'))::int desc limit 1),
                 case when v_coleta_pulso is null then 'ainda sem batimento'
                      else format('%s fluxos lidos às %s', f_n, public._pulso_hm(v_coleta_pulso)) end),
        case when v_coleta_pulso is null then 'o pulso_coleta lê o n8n a cada 5 min' when v_av_txt is not null then v_av_txt
             when f_nivel = 'ok' then 'todos no horário' else format('%s de %s no horário', f_ok, f_n) end]),
      'motivos', case when v_av_txt is not null then jsonb_build_array(v_av_txt || ' — um a um em Mari › Erros') else '[]'::jsonb end,
      'erros_outros_fluxos', v_outros, 'avisos_governanca', v_gov,
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
  g_titulo := case g_nivel when 'ok' then 'Saúde do ecossistema'
                           when 'parado' then format('%s %s', ROT->>g_elo, case when g_elo in ('mari', 'entrada') then 'parada' else 'parado' end)
                           when 'atencao' then format('%s em atenção', ROT->>g_elo)
                           else format('%s sem leitura', ROT->>g_elo) end;
  if g_elo = 'mari' and g_nivel = 'atencao' and v_so_conexao then g_titulo := 'Conexão com o banco em atenção'; end if;
  if g_elo is not null then
    select inicio_em into g_desde from public.pulso_incidentes where parceiro_id = 'dharma' and elo = g_elo and fim_em is null;
  end if;
  if g_elo = 'mari' then
    -- 0183: a frase sai do que foi medido. Só fala em cliente esperando quando há cliente esperando.
    if v_esperando > 0 then
      al_texto := format('%s cliente%s esperando resposta (o mais antigo há %s min) e ', v_esperando,
                         case when v_esperando = 1 then '' else 's' end, v_espera_max)
               || case when m_rot = 'sem crédito' then 'a Mari está sem crédito na API do Claude'
                       when v_ult_resp is not null then format('a Mari não responde desde %s', public._pulso_hm(v_ult_resp))
                       else 'a Mari não está respondendo' end || '.';
    else
      al_texto := 'Mari: ' || coalesce(m_mot[1], m_rot) || '. ' || initcap(left(m_linhas[1], 1)) || substr(m_linhas[1], 2) || '.';
    end if;
    al_acao := case when v_esperando > 0 then 'esperando' else 'erro' end; al_n := v_esperando;
    if g_nivel = 'atencao' and v_so_conexao then
      al_texto := upper(left(v_cx_txt, 1)) || substr(v_cx_txt, 2) || '. '
               || case when v_esperando = 0 then 'Ninguém esperando resposta da Mari.'
                       else format('%s cliente%s esperando resposta.', v_esperando, case when v_esperando = 1 then '' else 's' end) end;
    end if;
  elsif g_elo = 'entrada' then
    al_texto := format('A Meta gastou R$ %s hoje e %s', replace(to_char(v_gasto, 'FM999G990D00'), '.', ','),
                       case when v_meta_hoje = 0 then 'nenhuma conversa do anúncio entrou — suspeita de webhook ou WhatsApp.'
                            else format('só %s conversa%s do anúncio entrou (esperado %s).', v_meta_hoje, case when v_meta_hoje = 1 then '' else 's' end, round(v_esperado)) end);
    al_acao := 'erro';
  elsif g_elo = 'meta' then
    al_texto := 'Anúncios: ' || coalesce(a_mot[1], a_rot) || '.'; al_acao := 'meta';
  elsif g_elo = 'fluxos' then
    al_texto := case when f_rot = 'erros de outros fluxos' then 'Fluxos do n8n: ' || v_av_txt || ' (ver Mari › Erros).'
                     else 'Fluxo do n8n: ' || (elos->'fluxos'->'linhas'->>0) || '.' end;
    al_acao := 'erro';
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
end $function$;
