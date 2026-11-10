-- NIOGEN | supabase/migrations/0095_atendimento_sem_limites.sql | 09/11/2026 — Claude Code
-- Ricardo (09/11 ~22h50): "Precisa remover essas restrições de atendimento por dentro do Niogen, tanto limites de horário como
-- número de mensagens enviadas." (Antes: "Não se preocupa com essa questão de contar mensagem enviada.")
--   · backoffice_responder (caixa de resposta do NIOGEN): sem o horário do contrato e sem o teto de 2/dia · 15/mês.
--   · _bo_mensagem (mensagens dos botões: aviso do pedido, confirmação da instalação, outro CPF): saem na hora do clique, sem
--     horário e sem teto. Continuam: cliente "não contatar" e a janela de 24 h do WhatsApp (fora dela, só template aprovado —
--     regra da Meta, não nossa).
--   · Os contatos seguem registrados em contatos_cliente (ativo/receptivo) para a medição.
--   · A cadência automática da Mari (mari_cadencia) NÃO muda.

CREATE OR REPLACE FUNCTION public._bo_mensagem(p_grupo uuid, p_ordem integer, p_momento text, p_venda uuid, c mari_conversas, p_chave text, p_vars jsonb, p_template text DEFAULT NULL::text, p_tpl_params jsonb DEFAULT NULL::jsonb, p_rotulo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_txt    text;
  v_quando timestamptz;
  v_tq     record;
  v_fila_d int; v_fila_m int;
  v_janela boolean;
  v_motivo text;
  v_tpl    public.config_templates_waba;
  v_pay    jsonb;
  k        text;
begin
  select texto into v_txt from public.config_mari_textos where chave = p_chave;
  if v_txt is null then raise exception 'Texto % não está em config_mari_textos.', p_chave; end if;
  for k in select jsonb_object_keys(coalesce(p_vars, '{}'::jsonb)) loop
    v_txt := replace(v_txt, '{' || k || '}', coalesce(p_vars ->> k, ''));
  end loop;

  -- 0095 (Ricardo, 09/11): o operador apertou o botão agora → a mensagem sai agora. Sem horário do contrato e sem o teto de
  -- 2/dia · 15/mês nas mensagens do NIOGEN (a cadência automática da Mari segue com as regras dela). Fica só: não contatar.
  v_quando := now();
  if c.nao_contatar then
    v_motivo := 'cliente pediu para não ser contatado';
  end if;

  -- Janela de 24 h (a cadência usa 23 h de folga): aberta se a mensagem SAIR antes de fechar.
  v_janela := c.ultima_msg_lead_at is not null and coalesce(v_quando, now()) < c.ultima_msg_lead_at + interval '23 hours';
  v_pay := jsonb_build_object('content', v_txt, 'message_type', 'outgoing', 'private', false, 'texto_chave', p_chave,
                              'rotulo', coalesce(p_rotulo, p_chave));
  if v_motivo is null and not v_janela then
    if p_template is not null then
      select * into v_tpl from public.config_templates_waba where nome = p_template and status = 'APPROVED';
    end if;
    if v_tpl.nome is null then
      v_motivo := 'janela de 24 h fechada e sem template aprovado para esta mensagem';
    else
      v_txt := public.mari_render_template(v_tpl.nome, p_tpl_params);
      v_pay := v_pay || jsonb_build_object('content', v_txt, 'content_type', 'text', 'template', v_tpl.nome,
        'template_params', jsonb_build_object('name', v_tpl.nome, 'category', v_tpl.categoria, 'language', v_tpl.idioma,
          'processed_params', jsonb_build_object('body',
            coalesce((select jsonb_object_agg((o)::text, e) from jsonb_array_elements_text(coalesce(p_tpl_params, '[]'::jsonb))
                       with ordinality as t(e, o)), '{}'::jsonb))));
    end if;
  end if;

  if v_motivo is not null then
    perform public._bo_enfileirar(p_grupo, p_ordem, p_momento, p_venda, c, 'mensagem', v_pay || jsonb_build_object('motivo', v_motivo),
                                  now(), 'bloqueada', v_motivo);
    return jsonb_build_object('status', 'bloqueada', 'motivo', v_motivo, 'texto', v_txt);
  end if;
  perform public._bo_enfileirar(p_grupo, p_ordem, p_momento, p_venda, c, 'mensagem', v_pay, v_quando);
  return jsonb_build_object('status', 'pendente', 'quando', v_quando, 'template', v_pay ->> 'template', 'texto', v_txt);
end;
$function$;

CREATE OR REPLACE FUNCTION public.backoffice_responder(p_conversa uuid, p_texto text, p_nota boolean DEFAULT false, p_template text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c        public.mari_conversas;
  g        uuid := gen_random_uuid();
  o        int := 0;
  quem     text;
  agente   int;
  v_time   int := (public._bo_cfg('chatwoot_time_backoffice', '15102') #>> '{}')::int;
  txt      text := btrim(coalesce(p_texto, ''));
  aid      bigint;
  assumiu  boolean := false;
  ult_lead timestamptz;
  ult_out  timestamptz;
  resposta boolean;
  v_tq     record;
  v_fila_d int; v_fila_m int;
  v_prox   timestamptz;
  v_tpl    public.config_templates_waba;
  v_pay    jsonb;
  v_nome   text;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice responde pelo NIOGEN.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.canal <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' then raise exception 'Esta conversa não está no Chatwoot.'; end if;
  if c.telefone like '5500000000%' then raise exception 'Telefone de teste: nada vai ao Chatwoot.'; end if;
  if p_template is null and txt = '' then raise exception 'Escreva a mensagem.'; end if;
  if length(txt) > 4000 then raise exception 'Mensagem longa demais (máx. 4.000 caracteres).'; end if;
  select nome, chatwoot_agente_id into quem, agente from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');

  -- Nota privada: só o time vê; não é contato com o cliente.
  if coalesce(p_nota, false) then
    if txt = '' then raise exception 'Escreva a nota.'; end if;
    aid := public._bo_enfileirar(g, 1, 'nota', c.venda_id, c, 'nota', jsonb_build_object('content', txt, 'como', 'humano'));
    return jsonb_build_object('ok', true, 'acao_id', aid, 'nota', true, 'resumo', '✓ nota privada salva no Chatwoot (só o time vê)');
  end if;

  if coalesce(c.nao_contatar, false) then raise exception 'O cliente pediu para não ser contatado.'; end if;
  -- 0095 (Ricardo, 09/11): atendimento pelo NIOGEN SEM limite de horário e SEM teto de mensagens. Só se registra se foi
  -- resposta a quem falou por último (contato receptivo) ou contato ativo — para a medição, não para bloquear.
  select max(t.created_at) filter (where t.papel = 'lead'), max(t.created_at) filter (where t.papel in ('mari', 'humano'))
    into ult_lead, ult_out from public.mari_turnos t where t.conversa_id = c.id;
  resposta := ult_lead is not null and ult_lead > now() - interval '24 hours'
              and (ult_lead > coalesce(ult_out, '-infinity'::timestamptz)
                   or exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'mensagem'
                               and a.payload ->> 'conta' = 'nao' and a.criada_em > ult_lead and a.criada_em > now() - interval '30 minutes'));
  -- Janela de 24 h: é regra do WhatsApp (a Meta recusa texto livre depois dela), não do contrato. Fechada → só template aprovado.
  if p_template is not null then
    select * into v_tpl from public.config_templates_waba where nome = p_template and status = 'APPROVED' and nome like 'nio\_%';
    if v_tpl.nome is null then raise exception 'Template não aprovado: %', p_template; end if;
    if (select count(*) from regexp_matches(coalesce(v_tpl.corpo, ''), '\{\{[0-9]+\}\}', 'g')) > 1 then
      raise exception 'Este template precisa de mais dados; mande pelo Chatwoot.';
    end if;
    v_nome := public.mari_cadencia_nome(c);
    v_pay := jsonb_build_object('content', public.mari_render_template(v_tpl.nome, jsonb_build_array(v_nome)), 'content_type', 'text',
      'message_type', 'outgoing', 'private', false, 'template', v_tpl.nome,
      'template_params', jsonb_build_object('name', v_tpl.nome, 'category', v_tpl.categoria, 'language', v_tpl.idioma,
        'processed_params', jsonb_build_object('body', jsonb_build_object('1', v_nome))));
  else
    if ult_lead is null or now() >= ult_lead + interval '23 hours' then
      raise exception 'A janela de 24 h fechou: só template aprovado. Escolha um em "Respostas rápidas › Templates".' using errcode = 'P0001';
    end if;
    v_pay := jsonb_build_object('content', txt, 'message_type', 'outgoing', 'private', false);
  end if;
  v_pay := v_pay || jsonb_build_object('como', 'humano', 'conta', case when resposta then 'nao' else 'sim' end, 'rotulo', 'resposta do time');

  -- Sem dono → assume antes (a Mari cala, a cadência para).
  if c.chatwoot_agente is null and not coalesce(c.humano_atribuido, false) then
    perform public.mari_cadencia_parar(c.id, p_humano => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[assumida no NIOGEN por ' || quem || ' ao responder — cadência parada]', false);
    o := o + 1;
    perform public._bo_enfileirar(g, o, 'assumir', c.venda_id, c, 'atribuir',
      case when agente is not null then jsonb_build_object('assignee_id', agente) else jsonb_build_object('team_id', v_time) end);
    assumiu := true;
  end if;
  o := o + 1;
  aid := public._bo_enfileirar(g, o, 'responder', c.venda_id, c, 'mensagem', v_pay);
  return jsonb_build_object('ok', true, 'acao_id', aid, 'resposta', resposta, 'assumiu', assumiu,
    'resumo', '✓ mensagem enviada' || case when assumiu then ' · conversa assumida (a Mari calou)' else '' end);
end;
$function$;
