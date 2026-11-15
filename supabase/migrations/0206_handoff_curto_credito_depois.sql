-- NIOGEN | supabase/migrations/0206_handoff_curto_credito_depois.sql | 15/11/2026 — Claude Code / Opus 5.5
-- Ricardo (15/11): "o handoff deve ser objetivo e orientar em poucas linhas o resumo e a orientação para o BKO" e trazer o
-- resultado da viabilidade e do crédito feitos pela Mari. A nota do handoff (n8n 7 · Extrair / 9d) ficou curta; esta é a
-- nota que vai quando o CRÉDITO chega DEPOIS do handoff (0140/0204): mesmo formato — "💳 Crédito chegou: …" e
-- "👉 Fazer agora: …". A tabela do "Fazer agora" é a mesma do n8n/mari/n07_extrair.js e do docs/assets/ficha.js
-- (handoffFazer) — mudou uma, muda as três.
-- Corpo = mari_credito_gravar da 0204 (conferido igual ao vivo em 15/11), trocado só o texto da nota e o returning
-- (forma_pagamento e credito_consultas para o "Fazer agora"). Nada muda no que se grava.

create or replace function public.mari_credito_gravar(p_conversa uuid, p_saida jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_op text := p_saida->>'resultado'; v text; c record; v_formas text; v_fp text; v_fazer text;
        v_end text := case when p_saida->'endereco'->>'origem' = 'cliente' then 'cliente' when p_saida->'endereco'->>'origem' = 'padrao' then 'padrao' end;
begin
  if coalesce(p_saida->>'retry', '') = 'true' then
    update public.mari_conversas set credito_em = null, credito_consultas = greatest(credito_consultas - 1, 0)
     where id = p_conversa and credito_resultado is null;
    return jsonb_build_object('ok', true, 'resultado', 'de_volta_na_fila');
  end if;
  v := case when v_op in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'pedido_em_andamento')
            then v_op else 'nao_decidiu' end;
  update public.mari_conversas set credito_resultado = v, credito_em = now(), credito_endereco = v_end,
         credito_formas = case when jsonb_typeof(p_saida->'formas_liberadas') = 'array' then p_saida->'formas_liberadas' end,
         nio_pedido_aberto = case when v = 'pedido_em_andamento' then 'sim' else nio_pedido_aberto end
   where id = p_conversa returning id, venda_id, credito_autorizado_em, credito_autorizacao_frase, chatwoot_conversation_id, status,
                                   forma_pagamento, credito_consultas into c;
  if c.id is null then return jsonb_build_object('ok', false, 'motivo', 'conversa não encontrada'); end if;
  insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cpf_mascara, resultado, detalhe, ms)
  values ('credito', 'mari', p_conversa, c.venda_id, p_saida->>'cpf_mascara', coalesce(v_op, 'erro'),
          jsonb_strip_nulls(jsonb_build_object('formas', p_saida->'formas_liberadas', 'motivo', p_saida->>'motivo',
            'cache', p_saida->'cache', 'etapa_parada', p_saida->'etapa_parada', 'endereco', v_end,
            'autorizado_em', c.credito_autorizado_em, 'autorizacao_frase', c.credito_autorizacao_frase)),
          nullif(p_saida->>'ms', '')::int);
  -- 0140: o resultado chegou depois do handoff (a nota da Mari já foi) → nota interna no Chatwoot pela fila do NIOGEN.
  if c.chatwoot_conversation_id is not null and (c.status = 'handoff_realizado' or c.venda_id is not null) then
    v_formas := (select string_agg(case upper(x) when 'BOLETO' then 'boleto' when 'CREDITO' then 'cartão' when 'DACC' then 'débito em conta' else lower(x) end, ', ')
                   from jsonb_array_elements_text(case when jsonb_typeof(p_saida->'formas_liberadas') = 'array' then p_saida->'formas_liberadas' else '[]'::jsonb end) x);
    v_fp := case c.forma_pagamento when 'boleto' then 'boleto' when 'cartao' then 'cartão' when 'debito' then 'débito em conta' end;
    v_fazer := case
      when v = 'pedido_em_andamento' then 'NÃO abrir outro pedido: conferir no portal o pedido que já existe no CPF (recompra = multa R$ 500).'
      when v_end = 'padrao' and v like 'aprovado%' then 'Consultar o crédito de novo no endereço do cliente (ficha › Crédito) antes de abrir o pedido.'
      when v = 'nao_decidiu' then 'Consultar o crédito na ficha (Crédito) — o portal não decidiu.'
      when v = 'pendente' then 'Aguardar a resposta da Nio (até 24 h) e avisar o cliente; não abrir o pedido antes.'
      when v = 'negado' and coalesce(c.credito_consultas, 0) >= 2 then 'Ver com o cliente outra pessoa da casa como titular; sem saída, encerrar pela Saída.'
      when v = 'negado' then 'Oferecer outra pessoa da casa como titular (CPF do parente → 1 nova consulta).'
      when v = 'aprovado_cartao' and coalesce(c.forma_pagamento, '') <> 'cartao' then 'Só o cartão foi liberado: confirmar se o cliente paga no cartão; se não, outra pessoa da casa como titular.'
      when v = 'aprovado_parcial' and c.forma_pagamento in ('boleto', 'cartao', 'debito')
           and not coalesce(p_saida->'formas_liberadas', '[]'::jsonb) ? (case c.forma_pagamento when 'boleto' then 'BOLETO' when 'cartao' then 'CREDITO' else 'DACC' end)
        then 'A forma escolhida (' || v_fp || ') não foi liberada: combinar com o cliente uma das liberadas (' || coalesce(v_formas, '?') || ').'
      else 'Gravar o crédito na ficha e abrir o pedido no portal' || coalesce(' no ' || v_fp, '') || '; avisar o cliente do link da biometria que a Nio manda.' end;
    insert into public.chatwoot_acoes (grupo, ordem, momento, venda_id, conversa_id, chatwoot_conversation_id, tipo, payload, status)
    values (gen_random_uuid(), 1, 'credito', c.venda_id, p_conversa, c.chatwoot_conversation_id, 'nota',
            jsonb_build_object('content', '💳 Crédito chegou (consulta automática da Mari'
              || coalesce(', ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), '') || '): '
              || case v when 'aprovado_todas' then 'APROVADO — todas as formas'
                        when 'aprovado_parcial' then 'APROVADO — ' || coalesce(v_formas, 'formas: ?')
                        when 'aprovado_cartao' then 'APROVADO SÓ NO CARTÃO'
                        when 'pendente' then 'PENDENTE (a Nio responde em até 24 h)'
                        when 'negado' then case when coalesce(c.credito_consultas, 0) >= 2 then 'NEGADO nos 2 CPFs (titular e parente)' else 'NEGADO neste CPF' end
                        when 'pedido_em_andamento' then 'já existe PEDIDO NIO EM ANDAMENTO no CPF'
                        else 'o portal não decidiu' end
              -- 0204: lido no endereço padrão → não vale para o endereço do cliente
              || case when v_end = 'padrao' and v like 'aprovado%' then ' · ⚠ lido no endereço PADRÃO, não no do cliente' else '' end
              || E'\n👉 Fazer agora: ' || v_fazer), 'pendente');
  end if;
  return jsonb_build_object('ok', true, 'resultado', v, 'endereco', v_end);
end $function$;
revoke all on function public.mari_credito_gravar(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.mari_credito_gravar(uuid, jsonb) to service_role;
