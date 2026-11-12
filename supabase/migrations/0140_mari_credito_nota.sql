-- NIOGEN | supabase/migrations/0140_mari_credito_nota.sql | 12/11/2026 — Claude Code
-- Crédito da Mari (0138): quando o resultado chega DEPOIS do handoff, vai uma nota interna no Chatwoot (fila chatwoot_acoes).

create or replace function public.mari_credito_gravar(p_conversa uuid, p_saida jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_op text := p_saida->>'resultado'; v text; c record;
begin
  if coalesce(p_saida->>'retry', '') = 'true' then
    update public.mari_conversas set credito_em = null, credito_consultas = greatest(credito_consultas - 1, 0)
     where id = p_conversa and credito_resultado is null;
    return jsonb_build_object('ok', true, 'resultado', 'de_volta_na_fila');
  end if;
  v := case when v_op in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'pedido_em_andamento')
            then v_op else 'nao_decidiu' end;
  update public.mari_conversas set credito_resultado = v, credito_em = now(),
         credito_formas = case when jsonb_typeof(p_saida->'formas_liberadas') = 'array' then p_saida->'formas_liberadas' end,
         nio_pedido_aberto = case when v = 'pedido_em_andamento' then 'sim' else nio_pedido_aberto end
   where id = p_conversa returning id, venda_id, credito_autorizado_em, credito_autorizacao_frase, chatwoot_conversation_id, status into c;
  if c.id is null then return jsonb_build_object('ok', false, 'motivo', 'conversa não encontrada'); end if;
  insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cpf_mascara, resultado, detalhe, ms)
  values ('credito', 'mari', p_conversa, c.venda_id, p_saida->>'cpf_mascara', coalesce(v_op, 'erro'),
          jsonb_strip_nulls(jsonb_build_object('formas', p_saida->'formas_liberadas', 'motivo', p_saida->>'motivo',
            'cache', p_saida->'cache', 'etapa_parada', p_saida->'etapa_parada',
            'autorizado_em', c.credito_autorizado_em, 'autorizacao_frase', c.credito_autorizacao_frase)),
          nullif(p_saida->>'ms', '')::int);
  -- 0140: o resultado chegou depois do handoff (a nota da Mari já foi) → nota interna no Chatwoot pela fila do NIOGEN.
  if c.chatwoot_conversation_id is not null and (c.status = 'handoff_realizado' or c.venda_id is not null) then
    insert into public.chatwoot_acoes (grupo, ordem, momento, venda_id, conversa_id, chatwoot_conversation_id, tipo, payload, status)
    values (gen_random_uuid(), 1, 'credito', c.venda_id, p_conversa, c.chatwoot_conversation_id, 'nota',
            jsonb_build_object('content', '💳 Crédito (consulta automática da Mari, autorizada pelo cliente'
              || coalesce(' em ' || to_char(c.credito_autorizado_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), '') || '): '
              || case v when 'aprovado_todas' then 'APROVADO — todas as formas'
                        when 'aprovado_parcial' then 'APROVADO — formas: ' || coalesce((select string_agg(x, ', ') from jsonb_array_elements_text(p_saida->'formas_liberadas') x), '?')
                        when 'aprovado_cartao' then 'APROVADO SÓ NO CARTÃO — se o cliente não usa cartão, outra pessoa da casa pode ser a titular'
                        when 'pendente' then 'PENDENTE (a Nio responde em até 24 h)'
                        when 'negado' then 'NEGADO neste CPF'
                        when 'pedido_em_andamento' then 'já existe PEDIDO NIO EM ANDAMENTO no CPF — conferir antes de abrir outro (recompra = multa R$ 500)'
                        else 'o portal não decidiu — consultar na Cobertura' end
              || '. Grave o resultado na ficha.'), 'pendente');
  end if;
  return jsonb_build_object('ok', true, 'resultado', v);
end $$;
revoke all on function public.mari_credito_gravar(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.mari_credito_gravar(uuid, jsonb) to service_role;
