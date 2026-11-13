-- NIOGEN | supabase/migrations/0167_mari_volta_depois_de_sem_cobertura.sql | 13/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 13/11 (conversa #86, Edilamar; portão P30): a Mari disse "a fibra ainda não chega… se o número ou o CEP estiver
-- diferente, me manda que eu confiro de novo", encerrou por sem cobertura e ficou muda quando a cliente voltou a escrever.
-- O que muda: só a mari_entrada (a de produção, pg_get_functiondef em 13/11, com um bloco a mais antes da janela pós-handoff).
-- Cliente que escreve depois de uma saída por sem cobertura reabre a conversa (até 3 voltas; nunca se alguém do time assumiu
-- ou falou, nem se pediu para parar). O resto do comportamento está no código da Mari (n05b e n07, mesmo commit).
-- Ensaio em transação desfeita com a própria #86: silencio=false, status ativo, etapa endereco, marca gravada.

CREATE OR REPLACE FUNCTION public.mari_entrada(p_telefone text, p_nome text, p_texto text, p_canal text DEFAULT 'teste'::text, p_origem text DEFAULT NULL::text, p_chatwoot_conversation_id text DEFAULT NULL::text, p_midia jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_tel  text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_conv public.mari_conversas;
  v_ts   timestamptz := clock_timestamp();
  v_orig text := case when p_origem in ('meta_ads', 'instagram', 'facebook', 'site', 'fila_vero', 'indicacao', 'direto', 'teste') then p_origem end;
  v_cw   text := nullif(btrim(coalesce(p_chatwoot_conversation_id, '')), '');
  v_pos  boolean;
  v_opt  boolean;   -- 0155: cliente pediu para parar (SAIR, PARAR…)
  v_posv boolean;   -- 0155: cliente já instalado → pós-venda, com o time
begin
  if v_tel !~ '^\d{10,15}$' then
    raise exception 'telefone inválido' using errcode = '22023';
  end if;

  select * into v_conv from public.mari_conversas
   where telefone = v_tel and canal = p_canal and status in ('ativo', 'handoff_realizado')
   for update;

  -- 0155 (D2): quem saiu pelo fim da cadência (encerrado_ia) e volta a escrever reaproveita a mesma linha, no mesmo degrau.
  if not found then
    update public.mari_conversas m
       set status = 'ativo', etapa = 'retomada', cadencia_passo = 'nenhum', cadencia_proximo_em = null,
           ciclo_anterior = jsonb_strip_nulls(jsonb_build_object('motivo', m.handoff_motivo, 'em', m.handoff_em, 'encerrado_em', now(),
                              'origem', 'cliente voltou depois do fim da cadência', 'venda_id', m.venda_id)),
           ciclos_encerrados = coalesce(m.ciclos_encerrados, 0) + 1,
           handoff_motivo = null, handoff_em = null, handoff_briefing = null, chatwoot_resolvida = false, processando_ate = null,
           chatwoot_conversation_id = coalesce(v_cw, m.chatwoot_conversation_id)
     where m.id = (select x.id from public.mari_conversas x
                    where x.telefone = v_tel and x.canal = p_canal and x.status = 'encerrado_ia'
                    order by x.updated_at desc limit 1)
    returning * into v_conv;
    if found then
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (v_conv.id, 'sistema', '[cliente voltou depois do fim da cadência — a conversa segue de onde parou]', false);
    end if;
  end if;

  if not found then
    insert into public.mari_conversas (telefone, nome_contato, canal, origem, chatwoot_conversation_id)
    values (v_tel, nullif(btrim(p_nome), ''), p_canal,
            coalesce(v_orig, case when p_canal = 'teste' then 'teste' else 'direto' end),
            p_chatwoot_conversation_id)
    returning * into v_conv;
  elsif v_conv.origem = 'direto' and v_orig in ('meta_ads', 'instagram', 'facebook', 'site', 'fila_vero', 'indicacao') then
    -- 0033: conversa que já existia sem origem conhecida ganha a 1ª origem identificada (link (IG)/(FB) ou anúncio).
    update public.mari_conversas set origem = v_orig where id = v_conv.id returning * into v_conv;
  end if;

  if v_conv.status = 'handoff_realizado' and p_canal = 'whatsapp' and v_cw is not null
        and v_conv.chatwoot_conversation_id is distinct from v_cw then
    perform public._mari_fechar_ciclo(v_conv.id, 'nova conversa no Chatwoot (' || v_cw || ')');
    update public.mari_conversas set chatwoot_conversation_id = v_cw
     where id = v_conv.id returning * into v_conv;
  end if;

  -- 0167 (Ricardo, 13/11; conversa #86): a Mari avisou "sem cobertura" e convidou o cliente a mandar o CEP ou o número certo.
  -- Se ele volta a escrever e ninguém do time assumiu, a conversa reabre na etapa do endereço para a Mari conferir de novo —
  -- até 3 voltas por conversa. dados.sem_cobertura_avisado guarda a hora do veredito: enquanto o endereço for o mesmo, a Mari
  -- sabe que já avisou e não repete; endereço novo zera o veredito (gatilho da 0133) e a consulta sai de novo.
  if v_conv.status = 'handoff_realizado' and v_conv.handoff_motivo = 'sem_cobertura' and v_conv.cobertura_decisao = 'sem_cobertura'
     and v_conv.cobertura_em is not null
     and not coalesce(v_conv.humano_atribuido, false) and v_conv.chatwoot_agente is null and not coalesce(v_conv.nao_contatar, false)
     and coalesce(case when v_conv.dados->>'sem_cobertura_voltas' ~ '^[0-9]+$' then (v_conv.dados->>'sem_cobertura_voltas')::int end, 0) < 3
     and not public._mari_optout(p_texto)
     and not exists (select 1 from public.mari_turnos t
                      where t.conversa_id = v_conv.id and t.papel = 'humano' and t.created_at > v_conv.handoff_em) then
    update public.mari_conversas m
       set status = 'ativo', etapa = 'endereco', handoff_motivo = null, handoff_em = null, handoff_briefing = null,
           chatwoot_resolvida = false,
           dados = coalesce(m.dados, '{}'::jsonb) || jsonb_build_object(
             'sem_cobertura_avisado', floor(extract(epoch from m.cobertura_em))::bigint,
             'sem_cobertura_voltas', coalesce(case when m.dados->>'sem_cobertura_voltas' ~ '^[0-9]+$' then (m.dados->>'sem_cobertura_voltas')::int end, 0) + 1)
     where m.id = v_conv.id
    returning * into v_conv;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (v_conv.id, 'sistema', '[cliente voltou a escrever depois do aviso de sem cobertura — a Mari confere o endereço de novo]', false);
  end if;

  v_pos := public._mari_pos_handoff(v_conv);

  v_opt  := public._mari_optout(p_texto);
  v_posv := coalesce(v_conv.funil_destino, '') = 'instalada';

  insert into public.mari_turnos (conversa_id, papel, texto, pendente, midia)
  values (v_conv.id, 'lead', coalesce(p_texto, ''), (v_conv.status = 'ativo' or v_pos) and not v_opt and not v_posv, public._midia_ok(p_midia));

  update public.mari_conversas
     set ultima_entrada_ts = v_ts,
         ultima_msg_lead_at = now(),
         nome_contato = coalesce(nome_contato, nullif(btrim(p_nome), '')),
         -- 0155: a trava "resolvida" da cadência cai quando o cliente escreve e a conversa segue em andamento
         chatwoot_resolvida = case when coalesce(funil_destino, 'em_andamento') = 'em_andamento' then false else chatwoot_resolvida end
   where id = v_conv.id;

  if v_opt then perform public.conversa_nao_contatar(v_conv.id, 'cliente escreveu: ' || left(btrim(coalesce(p_texto, '')), 40)); end if;
  if v_posv and not v_opt then perform public._mari_pos_venda(v_conv.id); end if;

  return jsonb_build_object(
    'conversa_id', v_conv.id,
    'ts', v_ts,
    'status', v_conv.status,
    'silencio', (v_conv.status <> 'ativo' and not v_pos) or v_opt or v_posv,
    'optout', v_opt, 'pos_venda', v_posv,   -- em handoff: humano conduz, Mari calada (salvo a janela 0061)
    'pos_handoff', v_pos,
    'nova', v_conv.created_at >= now() - interval '1 second');
end;
$function$;
