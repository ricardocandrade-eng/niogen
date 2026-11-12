-- NIOGEN | supabase/migrations/0125_silenciar_textos_volta.sql | 11/11/2026 — Claude Code
-- Acompanha a 0124: a RPC backoffice_conversa_saida dizia (na nota do Chatwoot, no resumo e na lista "feito") que a silenciada
-- "não volta para o Live". Agora volta quando o cliente escreve — só os textos mudam; nenhuma regra, permissão ou fila muda.

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
  nomes   jsonb := '{"perdida": "Perdida (sem interesse)", "fora_area": "Fora de área", "ja_cliente": "Já é cliente Nio"}'::jsonb;
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
    perform public.mari_cadencia_parar(c.id, p_time => true);
    update public.mari_conversas
       set quadro_encerrada_motivo = 'suporte_nio', quadro_encerrada_em = now(), quadro_encerrada_por = auth.uid(), processando_ate = null
     where id = c.id;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[silenciada no NIOGEN por ' || quem || ' — cliente Nio, suporte/reclamação: não é venda]', false);
    feito := feito || 'fora do Live até ele escrever de novo'::text || 'cadência parada'::text;
    if tem_cw then
      perform public._bo_enfileirar(g, 1, 'silenciar', null, c, 'etiquetas',
        jsonb_build_object('add', jsonb_build_array('suporte-nio'), 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
      perform public._bo_enfileirar(g, 2, 'silenciar', null, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      perform public._bo_enfileirar(g, 3, 'silenciar', null, c, 'atribuir', jsonb_build_object('team_id', v_time));
      perform public._bo_enfileirar(g, 4, 'silenciar', null, c, 'nota', jsonb_build_object('content',
        '📵 Silenciada por ' || quem || ' em ' || agora_t || ': cliente Nio com suporte/reclamação — não é venda (somos revenda, '
        || 'não o suporte da Nio). Canal da Nio: App Nio ou 0800. A Mari não responde; se o cliente escrever de novo, a conversa volta para o time (Live e Conversas). '
        || 'Para desfazer: ficha da conversa no NIOGEN → Reativar.'));
      perform public._bo_enfileirar(g, 5, 'silenciar', null, c, 'resolver', jsonb_build_object('status', 'snoozed'));
      feito := feito || 'etiqueta suporte-nio'::text || 'time backoffice (a Mari cala)'::text || 'nota'::text || 'adiada no Chatwoot'::text;
    end if;
    return jsonb_build_object('ok', true, 'feito', to_jsonb(feito),
      'resumo', '✓ silenciada: a Mari não responde; se ele escrever de novo, volta para o time');

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
      perform public._bo_enfileirar(g, 2, 'saida', null, c, 'resolver', jsonb_build_object('status', 'resolved'));
      feito := feito || 'nota'::text || 'conversa resolvida'::text;
    end if;
    return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'resumo', '✓ Saída · ' || (nomes ->> p_motivo));
  end if;
  raise exception 'Motivo desconhecido: %', p_motivo;
end;
$function$;
