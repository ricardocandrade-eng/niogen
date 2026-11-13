-- NIOGEN | supabase/migrations/0183_pulso_so_erro_da_mari.sql | 13/11/2026 — Claude Code (Fable 5.2)
-- docs/Prompt_pulso_so_erro_da_mari_131126_1945.md (Cowork, 13/11 19h45): o pulso acusou "Mari falhando" 3 vezes no dia sem nenhum
-- cliente esperando. A tabela mari_erros virou a caixa de erro de todos os fluxos e de registros de governança, e o pulso lia tudo
-- o que não tinha nome de fluxo como falha da Mari (às 17h51, três falas do time digitadas no Chatwoot = "3 erros seguidos").
--   1. mari_erros.classe (mari | conexao | outro_fluxo | governanca), preenchida por gatilho a partir de config (regra 15):
--      config_regras.pulso_erros_conexao (já existia; ganha "closed unexpectedly") e a nova config_regras.pulso_erros_classes.
--      Sem regra que case, o erro é 'mari' — o alarme nunca se cala por engano. mari_erros ganha parceiro_id (regra 15).
--   2. pulso_operacao: "erros seguidos" e "erros hoje" contam só classe 'mari'; a queda de conexão segue com o nome da 0170;
--      erro de outro fluxo e registro de governança saem do elo Mari e viram linha do elo Fluxos (3 ou mais = atenção, nunca vermelho).
--   3. Vermelho com dono: a Mari só fica "parado" com cliente esperando (v_mari_sem_resposta) — ou sem crédito. Falha sem ninguém
--      esperando = atenção "com falhas". Chave config_regras.pulso_mari_parado_exige_espera (true; false volta ao que era).
--   4. A frase do alerta sai do que foi medido: só diz que há cliente esperando quando há.
--   5. live_conferir: a fala do time pelo Chatwoot já virava linha na Live › Conferir (funil_alerta, 0147); para lead com opt-out a
--      linha agora diz isso. conferencia_itens: item novo "Alarme da Mari só com cliente esperando" (esperado 0).
-- Não mexe no mari_principal nem no limite de 3 erros seguidos. Linhas antigas de mari_erros: só a coluna classe é preenchida.
-- pulso_operacao = 0170, live_conferir e conferencia_itens = 0182 (iguais à produção), com só esses trechos a mais.

-- ============================== config ==============================
update public.config_regras
   set valor = '{"no": "%Supabase%", "mensagens": ["%connection was aborted%", "%not able to process your request%", "%closed unexpectedly%"], "mensagens_qualquer_no": ["%connection to the server was closed unexpectedly%"]}'::jsonb,
       descricao = 'Pulso: erro de fluxo que conta como queda de conexão com o banco (classe conexao) — nome do nó (ilike) + trecho da mensagem (ilike); ou, em qualquer nó, um trecho de "mensagens_qualquer_no" (mensagem do próprio Postgres).'
 where chave = 'pulso_erros_conexao';

insert into public.config_regras (chave, valor, descricao, parceiro_id) values
  ('pulso_erros_classes',
   '{"regras": [
      {"classe": "governanca",  "no": ["resposta_fora_niogen", "jornada_furo"]},
      {"classe": "outro_fluxo", "no": ["ged360_desconhecido"]},
      {"classe": "outro_fluxo", "workflow_fora": ["mari_principal", "mari_midia_envio", "mari_viabilidade", "mari_credito", "mari_duplicidade"]}
    ]}'::jsonb,
   'Pulso: classe de cada linha de mari_erros que não é falha da Mari. Regras em ordem, a primeira que casa vale: "no" e "mensagem" = listas de padrões (ilike); "workflow_fora" = o erro veio de um fluxo do n8n que não está nesta lista (o caminho de resposta da Mari). Conexão com o banco vem antes (pulso_erros_conexao). Nada casou = mari.',
   'dharma'),
  ('pulso_mari_parado_exige_espera', 'true',
   'Pulso: a Mari só fica vermelha (parado) com cliente esperando resposta — ou sem crédito. false = volta a ficar vermelha só pelos erros.',
   'dharma')
on conflict (chave) do update set valor = excluded.valor, descricao = excluded.descricao;

-- ============================== mari_erros.classe ==============================
alter table public.mari_erros add column if not exists parceiro_id text not null default 'dharma';
alter table public.mari_erros add column if not exists classe text not null default 'mari';
alter table public.mari_erros drop constraint if exists mari_erros_classe_chk;
alter table public.mari_erros add constraint mari_erros_classe_chk check (classe in ('mari', 'conexao', 'outro_fluxo', 'governanca'));
create index if not exists mari_erros_created_idx on public.mari_erros (created_at desc);

create or replace function public._mari_erro_classe(p_no text, p_mensagem text, p_payload jsonb)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v_cx jsonb := (select valor from public.config_regras where chave = 'pulso_erros_conexao');
  v_rg jsonb := (select valor -> 'regras' from public.config_regras where chave = 'pulso_erros_classes');
  v_wf text := nullif(p_payload ->> 'workflow', '');
  r jsonb;
begin
  -- 1º: queda de conexão do n8n com o banco (nó do Supabase + mensagem de conexão)
  if jsonb_typeof(v_cx) = 'object'
     and coalesce(p_no, '') ilike any (case jsonb_typeof(v_cx -> 'no') when 'array' then array(select jsonb_array_elements_text(v_cx -> 'no'))
                                                                      else array[v_cx ->> 'no'] end)
     and coalesce(p_mensagem, '') ilike any (array(select jsonb_array_elements_text(v_cx -> 'mensagens'))) then
    return 'conexao';
  end if;
  if jsonb_typeof(v_cx -> 'mensagens_qualquer_no') = 'array'
     and coalesce(p_mensagem, '') ilike any (array(select jsonb_array_elements_text(v_cx -> 'mensagens_qualquer_no'))) then
    return 'conexao';
  end if;
  -- 2º: as regras da config, em ordem
  if jsonb_typeof(v_rg) = 'array' then
    for r in select x from jsonb_array_elements(v_rg) x loop
      if r ->> 'classe' in ('mari', 'conexao', 'outro_fluxo', 'governanca')
         and (r ? 'no' or r ? 'mensagem' or r ? 'workflow_fora')
         and (not r ? 'no' or coalesce(p_no, '') ilike any (array(select jsonb_array_elements_text(r -> 'no'))))
         and (not r ? 'mensagem' or coalesce(p_mensagem, '') ilike any (array(select jsonb_array_elements_text(r -> 'mensagem'))))
         and (not r ? 'workflow_fora' or (v_wf is not null and v_wf <> all (array(select jsonb_array_elements_text(r -> 'workflow_fora'))))) then
        return r ->> 'classe';
      end if;
    end loop;
  end if;
  return 'mari';
exception when others then
  return 'mari';   -- config quebrada nunca derruba o registro do erro nem cala o alarme
end $$;
revoke all on function public._mari_erro_classe(text, text, jsonb) from public, anon, authenticated;

create or replace function public._mari_erros_classe()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.classe := public._mari_erro_classe(new.no_n8n, new.mensagem, new.payload);
  return new;
end $$;
revoke all on function public._mari_erros_classe() from public, anon, authenticated;
drop trigger if exists mari_erros_classe on public.mari_erros;
create trigger mari_erros_classe before insert on public.mari_erros
  for each row execute function public._mari_erros_classe();

-- Backfill: só a coluna classe (nenhuma outra coluna das linhas antigas muda).
update public.mari_erros e set classe = public._mari_erro_classe(e.no_n8n, e.mensagem, e.payload)
 where e.classe is distinct from public._mari_erro_classe(e.no_n8n, e.mensagem, e.payload);

-- ============================== pulso_operacao ==============================
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

-- ============================== Live › Conferir e conferência diária ==============================
CREATE OR REPLACE FUNCTION public.live_conferir()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_horas numeric := coalesce((select (valor #>> '{}')::numeric from public.config_regras where chave = 'envelhecimento_dono_horas'), 24);
  v_docs  int := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'prazo_docs_dias'), 15);
  r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return '[]'::jsonb; end if;
  with nomes as (
    select c.id, c.venda_id,
           coalesce(nullif(btrim(c.dados ->> 'nome'), ''), nullif(btrim(c.nome_contato), ''), 'Contato') as nome,
           c.chatwoot_agente, c.funil_alerta, c.funil_alerta_em, coalesce(c.nao_contatar, false) as nao_contatar
      from public.mari_conversas c
     where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
  ),
  itens as (
    -- (a) ação do Chatwoot que falhou 3 vezes e não foi refeita depois
    select 'acao_falhou' as tipo, a.id::text as chave, a.conversa_id, a.venda_id, n.nome, a.criada_em as desde, 1 as ordem,
           format('O Chatwoot não obedeceu: %s%s', case a.tipo when 'resolver' then 'resolver / reabrir' when 'etiquetas' then 'etiqueta'
                    when 'atribuir' then 'atribuir' when 'desatribuir' then 'tirar a atribuição' when 'nota' then 'nota privada'
                    when 'mensagem' then 'mensagem ao cliente' else a.tipo end,
                  coalesce(' — ' || left(a.erro, 120), '')) as texto
      from public.chatwoot_acoes a
      left join nomes n on n.id = a.conversa_id
     where a.status = 'erro' and a.criada_em > now() - interval '7 days'
       and not exists (select 1 from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.tipo = a.tipo
                         and b.status = 'feita' and b.criada_em > a.criada_em)
    union all
    -- (b) conversa mexida direto no Chatwoot
    select 'fora_niogen', n.id::text, n.id, n.venda_id, n.nome, n.funil_alerta_em, 2,
           case n.funil_alerta
             when 'resolvida_fora_niogen' then 'Resolvida direto no Chatwoot, sem destino — registre a Saída (ou reabra)'
             when 'mensagem_fora_niogen' then case when n.nao_contatar   -- 0183
               then 'O time respondeu direto no Chatwoot a quem pediu para NÃO ser contatado — não escrever de novo; abrir a conversa no NIOGEN e conferir'
               else 'Respondida direto no Chatwoot — responda pelo NIOGEN para a venda andar' end
             when 'atribuida_fora_niogen' then 'Atribuída direto no Chatwoot a ' || coalesce(n.chatwoot_agente, 'alguém') || ' — a Mari calou; assuma pelo NIOGEN ou devolva para a Mari'
             else 'Adiada direto no Chatwoot — some da fila sem data de volta; use ⏸ Aguardar no NIOGEN' end
      from nomes n where n.funil_alerta is not null
    union all
    -- (c) conversa em andamento com dono e sem nenhuma fala há mais de N horas
    select case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido then 'handoff_parado' else 'dono_parado' end,
           c.id::text, c.id, c.venda_id, n.nome, u.ult, 3,
           format(case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido
                       then 'Passada pela Mari%s e ninguém pegou há %s — assumir, devolver para a Mari ou registrar a Saída'
                       else 'Com %s e parada há %s — retomar, devolver para a Mari ou registrar a Saída' end,
                  case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido then ''
                       else coalesce(c.chatwoot_agente, 'o time') end,
                  case when now() - u.ult >= interval '48 hours' then floor(extract(epoch from now() - u.ult) / 86400)::int || ' dias'
                       else floor(extract(epoch from now() - u.ult) / 3600)::int || ' h' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
      left join public.vendas v on v.id = c.venda_id
      cross join lateral (select max(t.created_at) as ult from public.mari_turnos t
                           where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano')) u
     where coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'
       and (c.humano_atribuido or c.time_atribuido or c.chatwoot_agente is not null or c.status = 'handoff_realizado')   -- 0155
       and not coalesce(c.nao_contatar, false)
       and c.quadro_encerrada_motivo is null
       and (c.espera_ate is null or c.espera_ate <= now())
       and coalesce(c.chatwoot_status, 'open') <> 'snoozed'
       and (v.id is null or v.status in ('0_qualificado', '1_vendido'))
       and not exists (select 1 from public.venda_pendencias vp where vp.venda_id = c.venda_id and vp.encerrada_em is null)
       and u.ult is not null and u.ult < now() - make_interval(mins => (v_horas * 60)::int)
    union all
    -- (d) documentos à Nio: 15 dias depois da instalação
    select 'docs_prazo', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), v.instalado_em, 4,
           case when v.instalado_em + make_interval(days => v_docs) < now()
                  then format('Documentos à Nio ATRASADOS — o prazo era %s', to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'))
                else format('Documentos à Nio até %s (%s dias depois da instalação)',
                            to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'), v_docs) end
      from public.vendas v
     where v.status in ('3_instalado', '4_ativo_provisorio') and v.instalado_em is not null and v.docs_entregues_em is null
       and v.instalado_em > now() - interval '90 days'
    union all
    -- (e) 0155: cliente já instalado escreveu e ninguém do time respondeu — pós-venda
    select 'pos_venda', c.id::text, c.id, c.venda_id, n.nome, u.ult_lead, 2,
           'Cliente já instalado escreveu — é pós-venda: responda você (a Mari não responde cliente instalado)'
      from public.mari_conversas c
      join nomes n on n.id = c.id
      cross join lateral (select max(t.created_at) filter (where t.papel = 'lead') as ult_lead,
                                 max(t.created_at) filter (where t.papel = 'humano') as ult_hum
                            from public.mari_turnos t where t.conversa_id = c.id) u
     where c.funil_destino = 'instalada' and u.ult_lead is not null and u.ult_lead > now() - interval '14 days'
       and u.ult_lead > coalesce(u.ult_hum, '-infinity') and u.ult_lead > coalesce(c.dispensada_em, '-infinity')
    union all
    -- (f) 0157: saiu com pedido ou OS aberta na Nio e ninguém confirmou o cancelamento no portal
    select 'cancelar_nio', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), ev.em, 2,
           'Saiu com pedido aberto na Nio' || coalesce(' (nº ' || coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) || ')', '')
             || ' — cancele no portal e confirme aqui. Pedido vivo trava o CPF e o endereço (recompra = multa de R$ 500)'
      from public.vendas v
      cross join lateral (select max(e.criado_em) as em from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'status') ev
     where v.status = 'saida' and v.instalado_em is null
       and (nullif(btrim(v.nio_pedido), '') is not null or nullif(btrim(v.nio_os), '') is not null)
       and coalesce(v.motivo_saida, '') not ilike 'Nio:%'
       and v.criado_em > now() - interval '90 days'
       and not exists (select 1 from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'cancelado_no_portal')
    union all
    -- (g) 0157 (D1): qualificado em andamento, sem fala do cliente há mais de N dias
    select case when l.tem_pedido_nio then 'silencio_com_pedido' else 'silencio_qualificado' end,
           l.lead_id, l.conversa_id, l.venda_id, l.nome, l.ultima_msg_lead_at, 3,
           case when l.tem_pedido_nio
                then format('Sem resposta do cliente há %s dias e com pedido aberto na Nio — insistir (ligar) ou cancelar na Nio e registrar a Saída',
                            floor(extract(epoch from now() - l.ultima_msg_lead_at) / 86400)::int)
                else format('Qualificado e sem resposta do cliente há %s dias — retomar ou registrar a Saída · Sem resposta',
                            floor(extract(epoch from now() - l.ultima_msg_lead_at) / 86400)::int) end
      from public.v_leads l
     where l.destino = 'em_andamento' and l.etapa in ('qualificado', 'instalacao') and l.status <> 'aguardando_instalacao'
       and not l.em_espera and l.venda_id is not null
       and l.ultima_msg_lead_at is not null
       and l.ultima_msg_lead_at < now() - make_interval(days => coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'saida_silencio_dias'), 15))    union all
    -- (h) 0157: saída com data de volta que chegou (recusou · momento, fachada em revisão) — vale também para conversa sem venda
    select 'volta_hoje', l.lead_id, l.conversa_id, l.venda_id, l.nome, l.volta_em::timestamptz, 3,
           format('Combinou voltar em %s (%s%s) — retomar o contato ou reabrir', to_char(l.volta_em, 'DD/MM'), l.saida_nome, coalesce(' · ' || l.saida_sub, ''))
      from public.v_leads l
     where l.destino = 'saida' and l.volta_em is not null
       and l.volta_em <= (now() at time zone 'America/Sao_Paulo')::date and l.volta_em > (now() at time zone 'America/Sao_Paulo')::date - 30
       and l.saida_motivo <> 'nao_contatar'
    union all
    -- (i) 0168: exceção da OS na Nio (Operador de OS e OSAB), com o valor em jogo e a ação
    select 'os_excecao', a.pedido, null::uuid, a.venda_id,
           coalesce(nullif(btrim(v.cliente_nome), ''), 'OS ' || a.pedido), coalesce(a.excecao_desde, a.mudou_em), 1,
           format('OS %s na Nio: %s%s%s — %s', a.pedido, coalesce(a.status_ordem, 'sem status'),
                  coalesce(' · ' || nullif(btrim(a.motivo_cancelamento), ''), ''),
                  case when coalesce(v.comissao_prevista, 0) > 0
                       then ' · R$ ' || replace(to_char(v.comissao_prevista, 'FM999990.00'), '.', ',') || ' de comissão em jogo' else '' end,
                  coalesce(a.acao, 'conferir na Consulta OS'))
      from public.os_andamento a
      left join public.vendas v on v.id = a.venda_id
     where a.excecao
    union all
    -- (j) 0175: a conta de hoje não fechou (conferência diária, etapa 6) — uma linha por falha
    select 'conta_nao_fecha', x ->> 'codigo', null::uuid, null::uuid, 'Conferência do dia', c.rodada_em, 1,
           format('A conta não fecha — %s: %s%s', x ->> 'nome', x ->> 'texto', coalesce(' → ' || nullif(x ->> 'fazer', ''), ''))
      from public.conferencias_diarias c
      cross join lateral jsonb_array_elements(c.itens) x
     where c.dia = (now() at time zone 'America/Sao_Paulo')::date and x ->> 'nivel' = 'falha'
    union all
    -- (k) 0182: risco de recompra — venda em andamento com CPF ou endereço repetido (só aviso; decisão do Ricardo, 13/11)
    select 'risco_recompra', rr.venda_id::text, null::uuid, rr.venda_id, coalesce(nullif(btrim(rr.cliente_nome), ''), 'Cliente'), rr.criado_em, 2,
           format('Risco de recompra — %s%s — conferir no portal ANTES de gravar o pedido e marcar "Conferi" na ficha (cliente ou endereço já na base = estorno de 100 %%; recompra = multa de R$ 500)',
                  rr.motivo, case when coalesce(rr.comissao_prevista, 0) > 0
                                  then ' · R$ ' || replace(to_char(rr.comissao_prevista, 'FM999990.00'), '.', ',') || ' de comissão em jogo' else '' end)
      from public.v_venda_risco_recompra rr
  )
  select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'chave', chave, 'conversa_id', conversa_id, 'venda_id', venda_id,
                                               'nome', nome, 'desde', desde, 'texto', texto) order by ordem, desde), '[]'::jsonb)
    into r from itens;
  return r;
end;
$function$;
revoke all on function public.live_conferir() from public, anon;
grant execute on function public.live_conferir() to authenticated;

CREATE OR REPLACE FUNCTION public.conferencia_itens(p_parceiro text DEFAULT 'dharma'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  it     jsonb := '[]'::jsonb;
  n      int;
  n2     int;
  ex     text;
  v_tot  int;
  v_soma int;
begin
  if not public._os_pode_gravar() then   -- admin, backoffice, chave de serviço ou CLI
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;

  -- 1. A soma dos destinos é o total de leads
  select count(*) into v_tot from public.v_leads;
  select coalesce(sum(c), 0) into v_soma from (select count(*) c from public.v_leads where destino is not null group by destino) x;
  it := it || jsonb_build_object('codigo', 'soma_destinos', 'nome', 'Soma dos destinos = total de leads',
    'nivel', case when v_tot = v_soma then 'ok' else 'falha' end, 'n', v_tot - v_soma,
    'texto', format('%s leads; os destinos somam %s', v_tot, v_soma),
    'fazer', case when v_tot = v_soma then null else 'Há lead sem destino: avisar o Claude Code (é defeito da v_leads).' end);

  -- 2. Lead em andamento sem vez / sem status · saída sem motivo
  select count(*), string_agg(nome, ', ' order by ultima_em desc) filter (where rn <= 5) into n, ex
    from (select nome, ultima_em, row_number() over (order by ultima_em desc) rn from public.v_leads
           where destino = 'em_andamento' and (vez is null or status is null)) x;
  it := it || jsonb_build_object('codigo', 'lead_sem_vez', 'nome', 'Todo lead em andamento tem status e vez',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todos com status e de quem é a vez' else format('%s lead(s) sem status ou sem vez: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Abrir cada um na Leads e registrar o que falta; se o sistema não deixar, avisar o Claude Code.' end);

  select count(*), string_agg(nome, ', ' order by ultima_em desc) filter (where rn <= 5) into n, ex
    from (select nome, ultima_em, row_number() over (order by ultima_em desc) rn from public.v_leads
           where destino = 'saida' and saida_motivo is null) x;
  it := it || jsonb_build_object('codigo', 'saida_sem_motivo', 'nome', 'Toda saída tem motivo',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as saídas com motivo da lista única' else format('%s saída(s) sem motivo: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Abrir a ficha e registrar o motivo da Saída.' end);

  -- 3. Prazo vencido (ninguém parado em silêncio): fecha, mas é para olhar hoje
  select count(*) into n from public.v_leads where destino = 'em_andamento' and atrasado and not em_espera;
  it := it || jsonb_build_object('codigo', 'atrasados', 'nome', 'Leads com o prazo da vez vencido',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum lead com prazo vencido' else format('%s lead(s) com o prazo vencido', n) end,
    'fazer', case when n = 0 then null else 'Leads › aba Precisam de ação.' end);

  -- 4. NIOGEN × Nio — venda sem pedido
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') filter (where rn <= 5) into n, ex
    from (select cliente_nome, row_number() over (order by criado_em desc) rn from public.vendas
           where status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio')
             and coalesce(nullif(btrim(nio_os), ''), nullif(btrim(nio_pedido), '')) is null) x;
  it := it || jsonb_build_object('codigo', 'venda_sem_pedido', 'nome', 'Toda venda tem o nº do pedido da Nio',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as vendas com pedido' else format('%s venda(s) sem nº de pedido: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Gravar o nº do pedido do portal na ficha.' end);

  -- 5. NIOGEN × Nio — OS aberta que o Operador de OS nunca leu (há mais de 6 h)
  select count(*), string_agg(ped, ', ') filter (where rn <= 5) into n, ex
    from (select coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) as ped,
                 row_number() over (order by v.criado_em desc) rn
            from public.vendas v
           where v.status in ('1_vendido', '2_aguardando_instalacao')
             and coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) ~ '^\d{8}$'
             and coalesce(v.nio_os_em, v.nio_pedido_em, v.vendido_em, v.criado_em) < now() - interval '6 hours'
             and not exists (select 1 from public.os_andamento a where a.parceiro_id = p_parceiro
                              and a.pedido = coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')))) x;
  it := it || jsonb_build_object('codigo', 'os_sem_leitura', 'nome', 'Toda OS aberta foi lida na Nio',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as OS abertas com leitura do Operador de OS' else format('%s OS sem nenhuma leitura: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Operações › ⟳ Varrer OS abertas. Se não ler, conferir o CPF e o nº da OS da venda.' end);

  -- 6. NIOGEN × Nio — a Nio enxerga pedido que o NIOGEN não tem
  select count(*) into n from public.portal_pedidos p
   where p.parceiro_id = p_parceiro and p.venda_id is null and upper(coalesce(p.tipo, '')) = 'VENDA'
     and p.ultima_leitura > now() - interval '30 days';
  select coalesce((i.resumo ->> 'sem_venda')::int, 0) into n2 from public.importacoes i
   where i.tipo = 'osab' and i.aplicado_em is not null order by i.aplicado_em desc limit 1;
  it := it || jsonb_build_object('codigo', 'pedido_sem_venda', 'nome', 'Pedido na Nio sem venda no NIOGEN',
    'nivel', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then 'ok' else 'atencao' end, 'n', coalesce(n, 0) + coalesce(n2, 0),
    'texto', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then 'nenhum pedido da Nio sem venda nossa'
                  else format('%s no Histórico do portal e %s no último OSAB', coalesce(n, 0), coalesce(n2, 0)) end,
    'fazer', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then null else 'Live › Conferir › casar o pedido com a venda (ou registrar a venda que falta).' end);

  -- 7. NIOGEN × Nio — texto novo da Nio sem tradução e exceção de OS parada há mais de 1 dia
  select count(*), string_agg(texto, ' · ') into n, ex from public.config_os_estados where parceiro_id = p_parceiro and estado is null;
  it := it || jsonb_build_object('codigo', 'os_texto_novo', 'nome', 'Textos da Nio traduzidos',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'todos os textos da OS conhecidos' else format('%s texto(s) sem tradução: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Avisar o Ricardo para traduzir (config_os_estados). Enquanto isso a venda não muda sozinha.' end);

  select count(*) into n from public.os_andamento where parceiro_id = p_parceiro and excecao and excecao_desde < now() - interval '1 day';
  it := it || jsonb_build_object('codigo', 'os_excecao_parada', 'nome', 'Exceção de OS tratada no mesmo dia',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma exceção de OS aberta há mais de 1 dia' else format('%s exceção(ões) de OS aberta(s) há mais de 1 dia', n) end,
    'fazer', case when n = 0 then null else 'Live › Conferir › linhas "OS … na Nio".' end);

  -- 8. NIOGEN × Chatwoot — conversa mexida fora e ação que o Chatwoot não obedeceu
  select count(*) into n from public.mari_conversas c
   where c.canal = 'whatsapp' and c.funil_alerta is not null and coalesce(c.telefone, '') not like '5500000000%';
  select count(*) into n2 from public.chatwoot_acoes a
   where a.status = 'erro' and a.criada_em > now() - interval '7 days'
     and not exists (select 1 from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.tipo = a.tipo
                       and b.status = 'feita' and b.criada_em > a.criada_em);
  it := it || jsonb_build_object('codigo', 'chatwoot', 'nome', 'NIOGEN e Chatwoot dizem a mesma coisa',
    'nivel', case when n + n2 = 0 then 'ok' else 'atencao' end, 'n', n + n2,
    'texto', case when n + n2 = 0 then 'nenhuma conversa mexida fora e nenhuma ação em erro'
                  else format('%s conversa(s) mexida(s) direto no Chatwoot · %s ação(ões) que o Chatwoot não obedeceu', n, n2) end,
    'fazer', case when n + n2 = 0 then null else 'Live › Conferir.' end);

  -- 9. Dinheiro — toda instalada tem a comissão prevista lançada
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') filter (where rn <= 5) into n, ex
    from (select v.cliente_nome, row_number() over (order by v.instalado_em desc) rn from public.vendas v
           where v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') and v.instalado_em is not null
             and coalesce(v.comissao_prevista, 0) > 0
             and not exists (select 1 from public.comissao_lancamentos l where l.venda_id = v.id and l.tipo = 'prevista')) x;
  it := it || jsonb_build_object('codigo', 'instalada_sem_previsto', 'nome', 'Toda instalada tem a comissão prevista lançada',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as instaladas com o previsto na razão da comissão' else format('%s instalada(s) sem o previsto: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: a razão da comissão não lançou o previsto.' end);

  -- 10. Dinheiro — previsto × extrato (só quando houver Extrato importado e conciliado: etapa 5c)
  select count(*) into n from public.comissao_lancamentos where parceiro_id = p_parceiro and origem = 'extrato';
  it := it || jsonb_build_object('codigo', 'previsto_extrato', 'nome', 'Comissão prevista × Extrato da Nio',
    'nivel', case when n = 0 then 'sem_dado' else 'ok' end, 'n', n,
    'texto', case when n = 0 then 'o Extrato da Nio ainda não foi conciliado (etapa 5c do plano)' else format('%s lançamento(s) do extrato', n) end,
    'fazer', null);

  -- 11. 0182 — risco de recompra: venda em andamento com CPF ou endereço repetido e ainda sem o "Conferi" (só aviso)
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') into n, ex from public.v_venda_risco_recompra;
  it := it || jsonb_build_object('codigo', 'risco_recompra', 'nome', 'Venda em andamento sem risco de recompra',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma venda em andamento com CPF ou endereço repetido' else format('%s venda(s) com CPF ou endereço repetido: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Conferir no portal antes de gravar o pedido e marcar "Conferi" na ficha. Recompra = multa de R$ 500.' end);

  -- 12. 0183 — o vermelho do pulso tem dono: incidente "Mari parada" sem nenhum cliente esperando (últimas 24 h; sem crédito não conta)
  select count(*), string_agg(to_char(inicio_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), ', ' order by inicio_em) into n, ex
    from public.pulso_incidentes
   where parceiro_id = p_parceiro and elo = 'mari' and nivel = 'parado' and clientes_esperando_max = 0
     and inicio_em > now() - interval '24 hours' and coalesce(motivo, '') not ilike 'sem crédito%';
  it := it || jsonb_build_object('codigo', 'pulso_mari_sem_espera', 'nome', 'Alarme da Mari só com cliente esperando',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum alarme vermelho da Mari sem cliente esperando nas últimas 24 h'
                  else format('%s alarme(s) vermelho(s) da Mari sem cliente esperando: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: o pulso acusou a Mari sem ninguém esperando (ver pulso_incidentes e Mari › Erros).' end);

  return it;
end;
$function$;
revoke all on function public.conferencia_itens(text) from public, anon;
grant execute on function public.conferencia_itens(text) to authenticated, service_role;
