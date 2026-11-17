-- NIOGEN | supabase/migrations/0267_fila_vero_rampa_500.sql | 17/11/2026 — Claude Code / Opus 5.5
-- Ricardo, 17/11 ~17h40: "Vamos seguir a cautela. Preciso chegar ao ponto de enviar pelo menos 500 mensagens ao dia e manter a
-- qualidade GREEN" → "Pode aplicar!". Os 12 opt-outs até aqui foram todos o botão "Não tenho interesse" (nenhum 131050): o botão
-- é o sinal bom (a pessoa sai sem bloquear). A trava de 3 % media o sinal errado. Nova rampa (fila_vero_rampa):
--   +100 a cada 2 dias até o teto de 500/dia (teto_max) se, nos últimos 2 dias: número GREEN o tempo todo (ultimo_nao_green_em),
--   zero 131050, nenhum template nio_fv_* rebaixado, e "Não tenho interesse" < 10 % dos entregues da janela.
-- Guarda (fila_vero_guarda, de hora em hora): lê também a nota dos templates (n8n B2b → p_leitura.templates); template YELLOW/RED
--   ou fora de APPROVED sai do disparo (_fv_template_ok troca a1↔a2; b1 sem troca → não envia) e avisa; "Não tenho interesse" do
--   dia > 15 % dos entregues do dia (com 30+ entregues) pausa e avisa. YELLOW/RED do número continua pausando na hora.
begin;

update public.config_regras
   set valor = valor || '{"max_optout": 0.10, "pausa_optout_dia": 0.15, "min_entregues_dia": 30, "teto_max": 500}'::jsonb,
       atualizado_em = now()
 where chave = 'fila_vero_rampa';

insert into public.config_regras (chave, valor, descricao) values
  ('fila_vero_templates_nota', '{}', 'Fila Vero: nota (quality_score) e status dos templates nio_fv_* na Meta, lidos de hora em hora pela guarda')
on conflict (chave) do nothing;

-- template que pode sair: o pedido, ou o par do A/B (a1↔a2) se o pedido estiver rebaixado; null se nenhum serve
create or replace function public._fv_template_ok(p_tpl text)
returns text language sql stable security definer set search_path = public as $$
  with n as (select coalesce(public._fv_cfg('fila_vero_templates_nota'), '{}'::jsonb) j),
  par as (select case p_tpl when 'nio_fv_a1' then 'nio_fv_a2' when 'nio_fv_a2' then 'nio_fv_a1' end p),
  ruim as (
    select t from n, par, unnest(array[p_tpl, par.p]) t
     where t is not null
       and (coalesce(n.j -> t ->> 'score', '') in ('YELLOW', 'RED')
            or coalesce(n.j -> t ->> 'status', 'APPROVED') <> 'APPROVED'))
  select case
    when not exists (select 1 from ruim where t = p_tpl) then p_tpl
    when (select p from par) is not null and not exists (select 1 from ruim, par where ruim.t = par.p) then (select p from par)
  end;
$$;

create or replace function public.fila_vero_rodada(p_max int default 10)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_ritmo int; v_hoje int; v_resto int; v_rodadas int; v_quota int; v_fim time; v_l timestamp;
        itens jsonb := '[]'::jsonb; r record; n_enc int := 0; v_tpl text; v_prox_a text := public._fv_template('instalado', 1, null);
begin
  if not public._os_pode_gravar() then raise exception 'Só serviço.' using errcode = '42501'; end if;
  -- saídas automáticas (regra 20.2): 2º toque sem clique/resposta há 7 dias → encerrado
  for r in select id from public.fila_vero
            where status = 'enviado' and toques >= 2 and ultimo_toque_em < now() - interval '7 days'
              and clicou_em is null and respondeu_em is null
  loop
    perform public.fila_vero_mudar(r.id, 'encerrado', '2 toques sem resposta (D+7)', 'rodada'); n_enc := n_enc + 1;
  end loop;
  -- respostas em texto no número do disparo → link da Mari (fora da cota)
  for r in select * from public.fila_vero_auto_respostas() loop
    itens := itens || jsonb_build_object('id', r.id, 'tipo', 'texto', 'telefone', r.telefone,
      'texto', 'Oi! Quem te atende é a Mari, da nossa equipe, pelo WhatsApp da Nio. Toque no link para falar com ela agora: '
               || 'https://niogen.dharmatelecom.com.br/fv.html?t=' || coalesce(upper(substr(r.template, 8)), 'A1') || '&c=' || r.codigo
               || E'\nSe não quiser mais receber, responda SAIR.');
  end loop;
  if coalesce((public._fv_cfg('fila_vero_ativo') #>> '{}')::boolean, false) is not true or not public.fila_vero_dentro_horario() then
    return jsonb_build_object('itens', itens, 'enviar', 0, 'encerrados', n_enc, 'motivo', 'desligado ou fora do horário');
  end if;
  v_ritmo := coalesce((public._fv_cfg('fila_vero_ritmo_dia') #>> '{}')::int, 100);
  v_hoje := public._fv_enviados_hoje();
  v_resto := greatest(0, v_ritmo - v_hoje);
  v_l := now() at time zone 'America/Sao_Paulo';
  v_fim := case when extract(isodow from v_l) = 6 then coalesce((public._fv_cfg('fila_vero_horario') #>> '{sabado,1}')::time, '16:00')
                else coalesce((public._fv_cfg('fila_vero_horario') #>> '{semana,1}')::time, '21:00') end;
  v_rodadas := greatest(1, ceil(extract(epoch from (v_fim - v_l::time)) / 300.0)::int);
  v_quota := least(p_max, ceil(v_resto::numeric / v_rodadas)::int);
  for r in
    with cand as (
      select fv.*, case when fv.status = 'enviado' then 2 else 1 end as toque
        from public.fila_vero fv
       where (fv.reservado_em is null or fv.reservado_em < now() - interval '15 minutes')
         and fv.telefone ~ '^55\d{2}9\d{8}$' and fv.lugar is not null
         and length(split_part(btrim(coalesce(fv.nome, '')), ' ', 1)) >= 2
         and ((fv.status = 'apto' and fv.toques = 0
               and (fv.faixa = 'endereco' or coalesce((public._fv_cfg('fila_vero_prioridade_b') #>> '{}')::boolean, true)))
           or (fv.status = 'enviado' and fv.toques = 1 and fv.ultimo_toque_em < now() - interval '3 days'
               and fv.clicou_em is null and fv.respondeu_em is null and fv.resposta_disparo_em is null
               and coalesce(fv.meta_status, '') <> 'failed'))
         and not exists (select 1 from public.mari_conversas c
                          where c.telefone in (fv.telefone, substr(fv.telefone, 1, 4) || substr(fv.telefone, 6))))
    select * from cand
     order by toque desc, (faixa = 'endereco') desc, md5(codigo)
     limit v_quota
  loop
    update public.fila_vero set reservado_em = now() where id = r.id;
    v_tpl := public._fv_template(r.segmento, r.toque, r.template1);
    if r.segmento = 'instalado' and r.toque = 1 and (public._fv_cfg('fila_vero_ab') ->> 'vencedor') is null then
      v_tpl := v_prox_a;                                   -- A/B: alterna a1/a2 também dentro da rodada
      v_prox_a := case v_prox_a when 'nio_fv_a1' then 'nio_fv_a2' else 'nio_fv_a1' end;
    end if;
    v_tpl := public._fv_template_ok(v_tpl);              -- 0267: template com nota baixa/pausado sai do disparo
    if v_tpl is null then
      update public.fila_vero set reservado_em = null where id = r.id;
      continue;
    end if;
    itens := itens || jsonb_build_object('id', r.id, 'tipo', 'template', 'telefone', r.telefone, 'toque', r.toque,
      'template', v_tpl, 'codigo', r.codigo,
      'params', jsonb_build_array(initcap(lower(split_part(btrim(r.nome), ' ', 1))), r.lugar));
  end loop;
  return jsonb_build_object('itens', itens, 'enviar', v_quota, 'ritmo', v_ritmo, 'hoje', v_hoje, 'encerrados', n_enc);
end $$;

-- ---------------------------------------------------------------- rampa (1x por dia, às 8h, chamada pela guarda)
create or replace function public.fila_vero_rampa()
returns jsonb language plpgsql security definer set search_path = public as $$
declare rp jsonb := public._fv_cfg('fila_vero_rampa'); q jsonb := public._fv_cfg('fila_vero_qualidade');
        nt jsonb := public._fv_cfg('fila_vero_templates_nota');
        v_ritmo int := coalesce((public._fv_cfg('fila_vero_ritmo_dia') #>> '{}')::int, 100);
        v_dias int := coalesce((public._fv_cfg('fila_vero_rampa') ->> 'dias')::int, 2); v_desde timestamptz;
        v_lim int; v_teto int; v_ent int; v_opt int; v_tx numeric; v_txa numeric; v_txb numeric; v_entb int; v_novo int;
        v_motivo text; v_131050 int; v_ruins text;
begin
  if not public._os_pode_gravar() then raise exception 'Só serviço.' using errcode = '42501'; end if;
  v_desde := now() - make_interval(days => v_dias);
  v_lim := case q ->> 'tier' when 'TIER_250' then 250 when 'TIER_1K' then 1000 when 'TIER_2K' then 2000 when 'TIER_10K' then 10000
                              when 'TIER_100K' then 100000 when 'TIER_UNLIMITED' then 100000 else 250 end;
  v_teto := least(floor(v_lim * coalesce((rp ->> 'teto_pct')::numeric, 0.6))::int, coalesce((rp ->> 'teto_max')::int, 500));
  -- janela da rampa: entregues e "Não tenho interesse" dos últimos v_dias ("não contatar" da Mari não conta)
  select count(*) into v_ent from public.fila_vero where entregue_em >= v_desde;
  select count(distinct e.fila_id) into v_opt from public.fila_vero_eventos e
   where e.para = 'opt_out' and e.em >= v_desde and coalesce(e.motivo, '') not like 'não contatar%';
  v_tx := v_opt::numeric / nullif(v_ent, 0);
  select count(*) into v_131050 from public.fila_vero where erro_codigo = '131050' and ultimo_toque_em >= v_desde;
  select string_agg(k, ', ') into v_ruins from jsonb_each(coalesce(nt, '{}'::jsonb)) x(k, v)
   where coalesce(v ->> 'score', '') in ('YELLOW', 'RED') or coalesce(v ->> 'status', 'APPROVED') <> 'APPROVED';
  -- faixa B rende 2x mais opt-out que a A (com 50+ entregues) → sai do disparo e avisa (sem mudança)
  select (count(*) filter (where status = 'opt_out' and toques > 0))::numeric / nullif(count(entregue_em), 0) into v_txa from public.fila_vero where faixa = 'endereco';
  select (count(*) filter (where status = 'opt_out' and toques > 0))::numeric / nullif(count(entregue_em), 0), count(entregue_em) into v_txb, v_entb from public.fila_vero where faixa = 'bairro';
  if v_entb >= 50 and coalesce(v_txa, 0) > 0 and v_txb >= 2 * v_txa
     and coalesce((public._fv_cfg('fila_vero_prioridade_b') #>> '{}')::boolean, true) then
    perform public._fv_cfg_set('fila_vero_prioridade_b', 'false');
    rp := rp || jsonb_build_object('alerta', format('faixa B (bairro) fora do disparo: opt-out %s%% contra %s%% da faixa A', round(100 * v_txb, 1), round(100 * v_txa, 1)));
  end if;
  if (rp ->> 'subiu_em') is not null and (rp ->> 'subiu_em')::timestamptz > v_desde then
    return rp || jsonb_build_object('ritmo', v_ritmo, 'teto', v_teto, 'optout', round(coalesce(v_tx, 0), 4));
  end if;
  if coalesce(q ->> 'rating', '') <> 'GREEN' then
    v_motivo := 'não subiu: qualidade ' || coalesce(q ->> 'rating', 'sem leitura');
  elsif (q ->> 'ultimo_nao_green_em') is not null and (q ->> 'ultimo_nao_green_em')::timestamptz > v_desde then
    v_motivo := format('não subiu: o número saiu do GREEN nos últimos %s dias', v_dias);
  elsif v_131050 > 0 then
    v_motivo := format('não subiu: %s bloqueio(s) de marketing (131050) nos últimos %s dias', v_131050, v_dias);
  elsif v_ruins is not null or ((rp ->> 'rebaixado_em') is not null and (rp ->> 'rebaixado_em')::timestamptz > v_desde) then
    v_motivo := 'não subiu: template rebaixado pela Meta' || coalesce(' (' || v_ruins || ')', ' nos últimos dias');
  elsif coalesce(v_tx, 0) >= coalesce((rp ->> 'max_optout')::numeric, 0.10) then
    v_motivo := format('não subiu: "Não tenho interesse" %s%% dos entregues dos últimos %s dias (máximo %s%%)',
                       round(100 * coalesce(v_tx, 0), 1), v_dias, round(100 * coalesce((rp ->> 'max_optout')::numeric, 0.10)));
  elsif v_ritmo >= v_teto then
    v_motivo := format('no teto: %s/dia', v_teto);
  else
    v_novo := least(v_teto, v_ritmo + coalesce((rp ->> 'passo')::int, 100));
    perform public._fv_cfg_set('fila_vero_ritmo_dia', to_jsonb(v_novo));
    v_motivo := format('subiu de %s para %s/dia (GREEN, sem 131050, "Não tenho interesse" %s%%)', v_ritmo, v_novo, round(100 * coalesce(v_tx, 0), 1));
    v_ritmo := v_novo;
  end if;
  rp := rp || jsonb_build_object('subiu_em', case when v_novo is not null then now() else (rp ->> 'subiu_em')::timestamptz end,
                                 'motivo', v_motivo, 'avaliado_em', now(), 'ritmo', v_ritmo, 'teto', v_teto, 'optout', round(coalesce(v_tx, 0), 4));
  perform public._fv_cfg_set('fila_vero_rampa', rp - 'alerta');
  return rp;
end $$;

-- ---------------------------------------------------------------- guarda (de hora em hora, n8n linha B)
create or replace function public.fila_vero_guarda(p_leitura jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_rating text := p_leitura ->> 'quality_rating'; v_status text := p_leitura ->> 'status'; v_alerta text; rp jsonb; v_hora int;
        q_ant jsonb := coalesce(public._fv_cfg('fila_vero_qualidade'), '{}'::jsonb);
        nt_ant jsonb := coalesce(public._fv_cfg('fila_vero_templates_nota'), '{}'::jsonb);
        nt jsonb := '{}'::jsonb; t jsonb; v_nome text; v_score text; v_st text; v_novos text; v_ok int; v_ent int; v_opt int; v_lim numeric;
        v_ativo boolean := coalesce((public._fv_cfg('fila_vero_ativo') #>> '{}')::boolean, false);
        v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if not public._os_pode_gravar() then raise exception 'Só serviço.' using errcode = '42501'; end if;
  perform public._fv_cfg_set('fila_vero_qualidade', jsonb_build_object('rating', v_rating, 'status', v_status,
    'tier', coalesce(p_leitura ->> 'whatsapp_business_manager_messaging_limit', p_leitura ->> 'messaging_limit_tier'),
    'nome', p_leitura ->> 'verified_name', 'nome_status', p_leitura ->> 'name_status', 'em', now(),
    'ultimo_nao_green_em', case when v_rating is not null and v_rating <> 'GREEN' then to_jsonb(now())
                                else q_ant -> 'ultimo_nao_green_em' end));
  -- 1) número YELLOW/RED ou fora do ar → pausa na hora (sem mudança)
  if (v_rating is not null and public._fv_cfg('fila_vero_pausa_qualidade') ? v_rating) or coalesce(v_status, 'CONNECTED') not in ('CONNECTED') then
    if v_ativo then
      v_alerta := format('disparo pausado — qualidade do número %s, status %s', coalesce(v_rating, '?'), coalesce(v_status, '?'));
      perform public.fila_vero_ligar(false, v_alerta); v_ativo := false;
    end if;
  end if;
  -- 2) nota dos templates nio_fv_* (só quando a leitura veio)
  if jsonb_typeof(p_leitura -> 'templates') = 'array' then
    for t in select * from jsonb_array_elements(p_leitura -> 'templates') loop
      v_nome := t ->> 'name';
      continue when v_nome is null or v_nome not like 'nio\_fv\_%';
      v_score := coalesce(t #>> '{quality_score,score}', 'UNKNOWN'); v_st := coalesce(t ->> 'status', '?');
      nt := nt || jsonb_build_object(v_nome, jsonb_build_object('score', v_score, 'status', v_st, 'em', now()));
      if (v_score in ('YELLOW', 'RED') or v_st <> 'APPROVED')
         and not (coalesce(nt_ant -> v_nome ->> 'score', '') in ('YELLOW', 'RED')
                  or coalesce(nt_ant -> v_nome ->> 'status', 'APPROVED') <> 'APPROVED') then
        v_novos := concat_ws(', ', v_novos, format('%s (%s, %s)', v_nome, v_score, v_st));
      end if;
    end loop;
    if nt <> '{}'::jsonb then
      perform public._fv_cfg_set('fila_vero_templates_nota', nt);
      if v_novos is not null then
        perform public._fv_cfg_set('fila_vero_rampa', public._fv_cfg('fila_vero_rampa') || jsonb_build_object('rebaixado_em', now()));
        select count(*) into v_ok from jsonb_each(nt) x(k, v) where v ->> 'score' not in ('YELLOW', 'RED') and v ->> 'status' = 'APPROVED';
        if v_ok = 0 and v_ativo then
          v_alerta := concat_ws(' · ', v_alerta, 'disparo pausado — todos os templates rebaixados: ' || v_novos);
          perform public.fila_vero_ligar(false, 'todos os templates rebaixados pela Meta'); v_ativo := false;
        else
          v_alerta := concat_ws(' · ', v_alerta, 'template saiu do disparo (rebaixado pela Meta): ' || v_novos);
        end if;
      end if;
    end if;
  end if;
  -- 3) "Não tenho interesse" do dia acima do limite → pausa
  rp := public._fv_cfg('fila_vero_rampa');
  v_lim := coalesce((rp ->> 'pausa_optout_dia')::numeric, 0.15);
  select count(*) into v_ent from public.fila_vero where (entregue_em at time zone 'America/Sao_Paulo')::date = v_hoje;
  select count(distinct fila_id) into v_opt from public.fila_vero_eventos
   where para = 'opt_out' and (em at time zone 'America/Sao_Paulo')::date = v_hoje and coalesce(motivo, '') not like 'não contatar%';
  if v_ativo and v_ent >= coalesce((rp ->> 'min_entregues_dia')::int, 30) and v_opt::numeric / v_ent > v_lim then
    v_alerta := concat_ws(' · ', v_alerta, format('disparo pausado — "Não tenho interesse" hoje %s de %s entregues (%s%%, limite %s%%)',
                                                  v_opt, v_ent, round(100.0 * v_opt / v_ent, 1), round(100 * v_lim)));
    perform public.fila_vero_ligar(false, format('"Não tenho interesse" do dia %s%%', round(100.0 * v_opt / v_ent, 1))); v_ativo := false;
  end if;
  perform public.fila_vero_escolher_vencedor();
  v_hora := extract(hour from now() at time zone 'America/Sao_Paulo');
  if v_hora = 8 then   -- rampa e faixa B: 1x por dia, antes da janela abrir
    rp := public.fila_vero_rampa();
    v_alerta := coalesce(v_alerta, rp ->> 'alerta');
  end if;
  return jsonb_build_object('alerta', v_alerta, 'rating', v_rating);
end $$;

revoke all on function public._fv_template_ok(text), public.fila_vero_rodada(int), public.fila_vero_rampa(),
  public.fila_vero_guarda(jsonb) from public, anon;

commit;
