-- NIOGEN | supabase/migrations/0261_cliente_nio_ninguem.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Regra do Ricardo (17/11 ~11h45, CLAUDE.md, regras de conteúdo da Mari): "Cliente já é Nio, em qualquer situação, educadamente a
-- Mari encerra a conversa, pedindo para procurar os canais oficiais. Se depois de alguns minutos o cliente insistir, silencie a
-- conversa. Somos uma revenda da Nio e não temos qualquer alçada para atender os clientes da Nio." Situação 15: ninguém, resolvida.
--   (1) mari_entrada: em "já é cliente Nio", depois da despedida (nossa fala junto ou depois da Saída), o cliente escreveu de novo →
--       silenciada sozinha (quadro suporte_nio), sem pessoa e sem time, adiada no Chatwoot, nota; silenciada = a Mari não responde.
--   (2) _funil_depois: toda Saída (fora instalada) tira handoff-venda/humano (a automação 24389/24390 devolvia o time); Cliente Nio
--       sai também da pessoa e do time.
--   (3) Silenciar manual (backoffice_conversa_saida 'suporte_nio'): não põe mais o time (a Mari cala pelo banco, item 1).
-- A despedida em si é do prompt da Mari (Bloco 5/7), publicado à parte. Funções recriadas a partir das que estão no ar (cópia
-- conferida). Regra 20: nenhum estado novo. Cenários: A5, A5t + o portão inteiro.
begin;

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
  v_opt  boolean;
  v_sil  boolean := false;   -- 0261: silenciada (cliente Nio)
  v_g    uuid;   -- 0155: cliente pediu para parar (SAIR, PARAR…)
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
  -- 0259 (A4, conferência da sombra): também com a conversa ATIVA (ex.: Saída "pode voltar", que fica ativa) — o cliente escreveu
  -- numa conversa nova do Chatwoot e o NIOGEN seguia mandando etiquetas, notas, mensagens e "resolver" na antiga, já resolvida.
  if p_canal = 'whatsapp' and v_cw is not null and v_conv.chatwoot_conversation_id is distinct from v_cw then
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (v_conv.id, 'sistema', '[o cliente escreveu numa conversa nova do Chatwoot (' || v_cw || ', antes ' || coalesce(v_conv.chatwoot_conversation_id, '—')
            || ') — o NIOGEN passa a usar a nova]', false);
    update public.mari_conversas set chatwoot_conversation_id = v_cw, chatwoot_status = 'open', chatwoot_agente = null, chatwoot_time = null,
           chatwoot_etiquetas = '{}'
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

  -- 0189 (Ricardo, 13/11; conversa #39, Waldir): saiu por recusa (ou por sem contato), clicou no anúncio de novo e a Mari
  -- ficou muda. Recusa não é pedido de parar: quem volta a escrever reabre na retomada, com a Mari. Não reabre se alguém do
  -- time é o dono, se o time falou nas últimas 12 h, se o cliente pediu para parar, nem na despedida logo depois da saída.
  if v_conv.status = 'handoff_realizado' and v_conv.handoff_motivo in ('recusa_compra', 'sem_contato')
     and not coalesce(v_conv.humano_atribuido, false) and v_conv.chatwoot_agente is null and not coalesce(v_conv.nao_contatar, false)
     and not public._mari_optout(p_texto)
     and coalesce(v_conv.handoff_em, '-infinity') < now() - interval '30 minutes'
     and not exists (select 1 from public.mari_turnos t
                      where t.conversa_id = v_conv.id and t.papel = 'humano' and t.created_at > now() - interval '12 hours') then
    perform public._mari_fechar_ciclo(v_conv.id, 'cliente voltou a escrever depois da saída');
    update public.mari_conversas set chatwoot_resolvida = false where id = v_conv.id returning * into v_conv;
  end if;

  -- 0261 (Ricardo, 17/11: "Cliente já é Nio, em qualquer situação, educadamente a Mari encerra a conversa, pedindo para procurar os
  -- canais oficiais. Se depois de alguns minutos o cliente insistir, silencie a conversa. Somos uma revenda da Nio"): conversa em
  -- "já é cliente Nio" em que já houve a despedida (a própria Mari deu a Saída, ou falamos depois dela) e o cliente escreve de novo → silenciada.
  if coalesce(v_conv.funil_destino, '') = 'ja_cliente_nio' and coalesce(v_conv.quadro_encerrada_motivo, '') <> 'suporte_nio'
     and (v_conv.handoff_motivo = 'ja_cliente_nio' or v_conv.ciclo_anterior ->> 'motivo' = 'ja_cliente_nio'   -- a Mari se despediu ao dar a Saída
          or exists (select 1 from public.mari_turnos t where t.conversa_id = v_conv.id and t.papel in ('mari', 'humano')
                      and t.created_at > coalesce(v_conv.funil_destino_em, v_conv.handoff_em, v_conv.created_at))) then
    update public.mari_conversas
       set quadro_encerrada_motivo = 'suporte_nio', quadro_encerrada_em = now(), quadro_encerrada_por = null, processando_ate = null,
           humano_atribuido = false, time_atribuido = false
     where id = v_conv.id returning * into v_conv;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (v_conv.id, 'sistema', '[cliente Nio insistiu depois da despedida — silenciada sozinha (0261): ninguém responde, canais oficiais da Nio]', false);
    if p_canal = 'whatsapp' and coalesce(v_conv.chatwoot_conversation_id, '') <> '' and v_conv.telefone not like '5500000000%' then
      v_g := gen_random_uuid();
      perform public._bo_enfileirar(v_g, 1, 'silenciar', null, v_conv, 'etiquetas',
        jsonb_build_object('add', jsonb_build_array('suporte-nio'), 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
      perform public._bo_enfileirar(v_g, 2, 'silenciar', null, v_conv, 'desatribuir', jsonb_build_object('assignee_id', null));
      perform public._bo_enfileirar(v_g, 3, 'silenciar', null, v_conv, 'desatribuir', jsonb_build_object('team_id', null));
      perform public._bo_enfileirar(v_g, 4, 'silenciar', null, v_conv, 'nota', jsonb_build_object('content',
        '📵 Silenciada sozinha: cliente que já é Nio insistiu depois da despedida da Mari. Somos revenda — sem alçada para atender cliente Nio. '
        || 'Canais oficiais: App Nio ou 0800 001 1000. Ninguém responde por aqui.'));
      perform public._bo_enfileirar(v_g, 5, 'silenciar', null, v_conv, 'resolver', jsonb_build_object('status', 'snoozed'));
    end if;
  end if;
  -- 0261: silenciada (cliente Nio) = a Mari não responde, e o time também não (situação 15: ninguém)
  v_sil := coalesce(v_conv.quadro_encerrada_motivo, '') = 'suporte_nio';

  v_pos := public._mari_pos_handoff(v_conv);

  -- 0250 (H2): Não contatar gravado no NIOGEN cala a Mari, mesmo que tirem a etiqueta à mão no Chatwoot
  v_opt  := public._mari_optout(p_texto) or coalesce(v_conv.nao_contatar, false);
  v_posv := coalesce(v_conv.funil_destino, '') = 'instalada';

  insert into public.mari_turnos (conversa_id, papel, texto, pendente, midia)
  values (v_conv.id, 'lead', coalesce(p_texto, ''), (v_conv.status = 'ativo' or v_pos) and not v_opt and not v_posv and not v_sil, public._midia_ok(p_midia));

  update public.mari_conversas
     set ultima_entrada_ts = v_ts,
         ultima_msg_lead_at = now(),
         nome_contato = coalesce(nome_contato, nullif(btrim(p_nome), '')),
         -- 0155: a trava "resolvida" da cadência cai quando o cliente escreve e a conversa segue em andamento
         chatwoot_resolvida = case when coalesce(funil_destino, 'em_andamento') = 'em_andamento' then false else chatwoot_resolvida end
   where id = v_conv.id;

  if v_opt and not coalesce(v_conv.nao_contatar, false) then perform public.conversa_nao_contatar(v_conv.id, 'cliente escreveu: ' || left(btrim(coalesce(p_texto, '')), 40)); end if;
  if v_posv and not v_opt then perform public._mari_pos_venda(v_conv.id); end if;

  return jsonb_build_object(
    'conversa_id', v_conv.id,
    'ts', v_ts,
    'status', v_conv.status,
    'silencio', (v_conv.status <> 'ativo' and not v_pos) or v_opt or v_posv or v_sil,
    'optout', v_opt, 'pos_venda', v_posv,   -- em handoff: humano conduz, Mari calada (salvo a janela 0061)
    'pos_handoff', v_pos,
    'nova', v_conv.created_at >= now() - interval '1 second');
end;
$function$;

CREATE OR REPLACE FUNCTION public._funil_depois()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  g     uuid := gen_random_uuid();
  lab   text;
  todas jsonb;
  tem_cw boolean := coalesce(new.chatwoot_conversation_id, '') <> '' and coalesce(new.telefone, '') not like '5500000000%'
                    and coalesce(new.canal, '') = 'whatsapp';
  ja_resolve boolean;
begin
  if tg_op = 'UPDATE' and new.funil_destino is not distinct from old.funil_destino then
    if new.funil_etapa is distinct from old.funil_etapa then
      insert into public.funil_eventos (conversa_id, tipo, de, para) values (new.id, 'etapa', old.funil_etapa, new.funil_etapa);
    end if;
    return null;
  end if;
  insert into public.funil_eventos (conversa_id, tipo, de, para, detalhe, por)
  values (new.id, 'destino', case when tg_op = 'UPDATE' then old.funil_destino end, new.funil_destino, new.funil_detalhe, auth.uid());

  if not tem_cw or new.funil_destino = 'teste_duplicada' then return null; end if;
  select coalesce(jsonb_agg(etiqueta), '[]'::jsonb) into todas from public.config_funil
   where parceiro_id = 'dharma' and tipo = 'destino' and etiqueta is not null;

  if new.funil_destino = 'em_andamento' then
    if tg_op = 'UPDATE' and old.funil_destino not in ('em_andamento', 'teste_duplicada') then
      perform public._bo_enfileirar(g, 1, 'destino', new.venda_id, new, 'etiquetas', jsonb_build_object('add', '[]'::jsonb, 'remove', todas));
    end if;
    return null;
  end if;

  select etiqueta into lab from public.config_funil where parceiro_id = 'dharma' and tipo = 'destino' and codigo = new.funil_destino;
  if lab is not null then
    perform public._bo_enfileirar(g, 1, 'destino', new.venda_id, new, 'etiquetas',
      jsonb_build_object('add', jsonb_build_array(lab), 'remove',
        -- 0261: Saída (fora instalada) tira também handoff-venda/humano — senão a automação do Chatwoot devolve o time
        (todas - lab) || case when new.funil_destino <> 'instalada' then '["handoff-venda", "handoff-humano"]'::jsonb else '[]'::jsonb end));
  end if;
  -- 0261 (Ricardo, 17/11): Cliente Nio é de ninguém — sai a pessoa e o time (somos revenda; canal da Nio: App Nio ou 0800)
  if new.funil_destino = 'ja_cliente_nio' then
    perform public._bo_enfileirar(g, 2, 'destino', new.venda_id, new, 'desatribuir', jsonb_build_object('assignee_id', null));
    perform public._bo_enfileirar(g, 3, 'destino', new.venda_id, new, 'desatribuir', jsonb_build_object('team_id', null));
  end if;
  -- instalada não resolve (o pós-venda segue na conversa); suporte Nio silenciado fica adiado com o time (a Mari não responde)
  if new.funil_destino = 'instalada' or new.quadro_encerrada_motivo = 'suporte_nio' then return null; end if;
  select exists (select 1 from public.chatwoot_acoes a where a.conversa_id = new.id and a.tipo = 'resolver'
                   and a.payload ->> 'status' = 'resolved' and a.criada_em > now() - interval '5 minutes'
                   and a.status in ('pendente', 'executando', 'feita')) into ja_resolve;
  if not ja_resolve and coalesce(new.chatwoot_status, 'open') <> 'resolved' then
    perform public._bo_enfileirar(g, 4, 'destino', new.venda_id, new, 'resolver', jsonb_build_object('status', 'resolved'));
  end if;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_funil_depois', sqlerrm);
  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION public.backoffice_conversa_saida(p_conversa uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c       public.mari_conversas;
  g       uuid := gen_random_uuid();
  v_time  int := (public._bo_cfg('chatwoot_time_backoffice', '15102') #>> '{}')::int;
  quem    text;
  agora_t text := to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
  nomes   jsonb := '{"perdida": "Recusou", "recusou": "Recusou", "fora_area": "Fora da área", "ja_cliente": "Já é cliente Nio", "ja_cliente_nio": "Já é cliente Nio", "sem_cobertura": "Sem cobertura", "credito_negado": "Crédito negado", "sem_resposta": "Sem resposta", "teste_duplicada": "Teste ou duplicada"}'::jsonb;  -- 0147: destinos canônicos (perdida/ja_cliente = nomes antigos)
  tem_cw  boolean;
  feito   text[] := '{}';
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null and p_motivo <> 'reativar' then
    raise exception 'Esta conversa já tem venda: use a Saída da venda.';
  end if;
  select nome into quem from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');
  tem_cw := coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%';

  if p_motivo = 'suporte_nio' then
    perform public.mari_cadencia_parar(c.id, p_resolvida => true);
    update public.mari_conversas
       set quadro_encerrada_motivo = 'suporte_nio', quadro_encerrada_em = now(), quadro_encerrada_por = auth.uid(), processando_ate = null,
           humano_atribuido = false, time_atribuido = false   -- 0261: ninguém (antes o time ficava para calar a Mari)
     where id = c.id;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[silenciada no NIOGEN por ' || quem || ' — cliente Nio, suporte/reclamação: não é venda]', false);
    feito := feito || 'fora do Live (mesmo se ele escrever)'::text || 'cadência parada'::text;
    if tem_cw then
      perform public._bo_enfileirar(g, 1, 'silenciar', null, c, 'etiquetas',
        jsonb_build_object('add', jsonb_build_array('suporte-nio'), 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
      perform public._bo_enfileirar(g, 2, 'silenciar', null, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      perform public._bo_enfileirar(g, 3, 'silenciar', null, c, 'desatribuir', jsonb_build_object('team_id', null));   -- 0261: ninguém
      perform public._bo_enfileirar(g, 4, 'silenciar', null, c, 'nota', jsonb_build_object('content',
        '📵 Silenciada por ' || quem || ' em ' || agora_t || ': cliente Nio com suporte/reclamação — não é venda (somos revenda, '
        || 'não o suporte da Nio). Canal da Nio: App Nio ou 0800. A Mari não responde e a conversa não volta para o Live (fica em Conversas › Todas, com o selo 📵). '
        || 'Para desfazer: ficha da conversa no NIOGEN → Reativar.'));
      perform public._bo_enfileirar(g, 5, 'silenciar', null, c, 'resolver', jsonb_build_object('status', 'snoozed'));
      feito := feito || 'etiqueta suporte-nio'::text || 'sem dono (ninguém atende — a Mari cala)'::text || 'nota'::text || 'adiada no Chatwoot'::text;
    end if;
    return jsonb_build_object('ok', true, 'feito', to_jsonb(feito),
      'resumo', '✓ silenciada: a Mari não responde e ela não volta para o Live');

  elsif p_motivo = 'reativar' then
    if coalesce(c.quadro_encerrada_motivo, '') <> 'suporte_nio' then
      return jsonb_build_object('ok', true, 'feito', '[]'::jsonb, 'resumo', 'A conversa não estava silenciada.');
    end if;
    update public.mari_conversas set quadro_encerrada_motivo = null, quadro_encerrada_em = null, quadro_encerrada_por = null where id = c.id;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[reativada no NIOGEN por ' || quem || ']', false);
    feito := feito || 'de volta no Live'::text;
    if tem_cw then
      perform public._bo_enfileirar(g, 1, 'reativar', null, c, 'etiquetas',
        jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('suporte-nio')));
      perform public._bo_enfileirar(g, 2, 'reativar', null, c, 'nota',
        jsonb_build_object('content', '🔔 Reativada por ' || quem || ' em ' || agora_t || ' — segue com o time; para a Mari voltar, "Devolver para a Mari".'));
      feito := feito || 'etiqueta tirada'::text || 'nota'::text;
    end if;
    return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'resumo', '✓ reativada: segue com o time backoffice');

  elsif nomes ? p_motivo then
    perform public.mari_cadencia_parar(c.id, p_resolvida => true);
    update public.mari_conversas
       set quadro_encerrada_motivo = p_motivo, quadro_encerrada_em = now(), quadro_encerrada_por = auth.uid(), processando_ate = null
     where id = c.id;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[encerrada no NIOGEN por ' || quem || ' — ' || (nomes ->> p_motivo) || ']', false);
    feito := feito || 'Saída'::text || 'cadência parada'::text;
    if tem_cw then
      perform public._bo_enfileirar(g, 1, 'saida', null, c, 'nota', jsonb_build_object('content',
        '⛔ Saída · ' || (nomes ->> p_motivo) || ' — ' || quem || ', ' || agora_t || '. Se o cliente escrever de novo, volta para o Live.'));
      -- 0147: etiqueta saida-<destino> e resolve saem pelo gatilho do funil (mari_conversas_funil_depois); teste resolve aqui
      if p_motivo = 'teste_duplicada' then
        perform public._bo_enfileirar(g, 2, 'saida', null, c, 'resolver', jsonb_build_object('status', 'resolved'));
      end if;
      feito := feito || 'nota'::text || 'etiqueta de saída'::text || 'conversa resolvida'::text;
    end if;
    return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'resumo', '✓ Saída · ' || (nomes ->> p_motivo));
  end if;
  raise exception 'Motivo desconhecido: %', p_motivo;
end;
$function$;

commit;
