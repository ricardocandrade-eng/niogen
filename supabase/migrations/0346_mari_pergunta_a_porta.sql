-- NIOGEN | supabase/migrations/0346_mari_pergunta_a_porta.sql | 21/11/2026 — Claude Code (Opus 5.5)
-- Fase 2, passo 4 (Ricardo, 21/11: "Sim, prepara"), lado do banco para a Mari e a cadência do n8n — o rascunho 0308 de 19/11
-- (supabase/rascunhos/0308_mari_pela_porta_RASCUNHO.sql), conferido contra a produção de 21/11 (as funções que ele usa têm a mesma
-- assinatura; os guards n02h/c06 não mudaram desde 19/11).
--  (1) mari_pode_falar(conversa do Chatwoot, para, passo): a pergunta "pode falar?" que troca os guards 2h (Mari) e 6h (cadência).
--      Responde pela SITUAÇÃO do lead e pelo NIOGEN, nunca pelo Chatwoot ao vivo. Mesmas regras dos guards de hoje.
--  (2) mari_chatwoot_pedir(conversa do Chatwoot, pedido, nota): o que hoje os nós 2p/2u, 9e/9f/9h e 9f da cadência fazem direto no
--      Chatwoot vira ORDEM NA FILA pela porta (_porta_ordem) — etiqueta sempre add/remove, nunca a lista inteira.
-- Só ACRESCENTA funções: nada muda no ar até o n8n passar a chamá-las (rascunho n8n/rascunhos/passo4_191126/, pelo portão da Mari).
-- Regra 20: (1) não cria situação; (2) sem estado novo; (3) quem grava é a porta (_porta_ordem); (4) fonte única: a situação no banco
-- em vez do Chatwoot ao vivo; (5) conferência: as ordens da Mari passam a aparecer em projetor_sombra (hoje ela escreve no Chatwoot
-- por fora da fila). Cenário X72.
begin;

create or replace function public._mari_pode_falar_decide(p_conversa_cw text, p_para text, p_passo text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
-- toda resposta leva também pessoa, time e nao_contatar (o 6p · Supabase parar da cadência grava esses campos)
declare
  c public.mari_conversas; s text; cs public.config_situacao;
  venda boolean := upper(coalesce(p_passo, '')) in ('INSTALACAO', 'VESPERA', 'CARTAO', 'CARTAO2', 'BIO1', 'BIOVOLTA');
  pessoa boolean; time_dono boolean; janela boolean;
begin
  select * into c from public.mari_conversas where chatwoot_conversation_id = p_conversa_cw and canal = 'whatsapp'
   order by (funil_destino = 'teste_duplicada'), updated_at desc nulls last limit 1;
  if c.id is null then
    return jsonb_build_object('pode', p_para = 'resposta', 'parar', false, 'motivo', 'conversa nova (o mari_entrada cria)');
  end if;
  s := public._porta_situacao(c.id, null::uuid);
  select * into cs from public.config_situacao where codigo = s;
  pessoa := coalesce(c.humano_atribuido, false) or c.chatwoot_agente is not null;
  time_dono := coalesce(c.time_atribuido, false) or c.chatwoot_time is not null;
  janela := time_dono and not pessoa and 'handoff-venda' = any (coalesce(c.chatwoot_etiquetas, '{}'::text[]));

  if coalesce(c.nao_contatar, false) then
    return jsonb_build_object('pode', false, 'parar', not venda, 'motivo', 'não contatar', 'situacao', s);
  end if;

  if p_para = 'lembrete' then
    if venda then
      if s in ('saida_pode_voltar', 'saida_definitiva') then
        return jsonb_build_object('pode', false, 'parar', false, 'motivo', 'aviso da venda: lead em Saída', 'situacao', s);
      end if;
      return jsonb_build_object('pode', true, 'parar', false, 'motivo', 'aviso da venda sai sempre', 'situacao', s);
    end if;
    if s = 'mari_atendendo' and not pessoa and not time_dono then
      return jsonb_build_object('pode', true, 'parar', false, 'motivo', 'Mari atendendo', 'situacao', s);
    end if;
    return jsonb_build_object('pode', false, 'parar', true, 'motivo', 'situação ' || s || ': lembrete da escada não sai', 'situacao', s);
  end if;

  -- resposta da Mari a quem escreveu
  if pessoa then
    return jsonb_build_object('pode', false, 'motivo', 'humano atribuído', 'situacao', s);
  end if;
  if time_dono and not janela then
    return jsonb_build_object('pode', false, 'motivo', 'time atribuído', 'situacao', s);
  end if;
  if janela then
    return jsonb_build_object('pode', true, 'motivo', 'time sem dono + handoff-venda — janela pós-handoff (banco decide)', 'situacao', s);
  end if;
  if coalesce(cs.mari, '') in ('não', 'nunca') then
    return jsonb_build_object('pode', false, 'motivo', 'situação ' || s || ': a Mari não fala', 'situacao', s);
  end if;
  return jsonb_build_object('pode', true, 'motivo', 'situação ' || s, 'situacao', s);
exception when others then
  return jsonb_build_object('pode', false, 'parar', false, 'motivo', 'erro no banco: ' || left(sqlerrm, 120));   -- sem resposta, não fala
end $$;

create or replace function public.mari_pode_falar(p_conversa_cw text, p_para text default 'resposta', p_passo text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.mari_conversas;
begin
  select * into c from public.mari_conversas where chatwoot_conversation_id = p_conversa_cw and canal = 'whatsapp'
   order by (funil_destino = 'teste_duplicada'), updated_at desc nulls last limit 1;
  return public._mari_pode_falar_decide(p_conversa_cw, p_para, p_passo)
      || jsonb_build_object('pessoa', coalesce(c.humano_atribuido, false) or c.chatwoot_agente is not null,
                            'time', coalesce(c.time_atribuido, false) or c.chatwoot_time is not null,
                            'nao_contatar', coalesce(c.nao_contatar, false));
exception when others then
  return jsonb_build_object('pode', false, 'parar', false, 'motivo', 'erro no banco: ' || left(sqlerrm, 120));
end $$;

create or replace function public.mari_chatwoot_pedir(p_conversa_cw text, p_pedido text, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c public.mari_conversas; g uuid := gen_random_uuid(); feito text[] := '{}'; tb int; antes text;
  hand text := case p_pedido when 'handoff_venda' then 'handoff-venda' when 'handoff_humano' then 'handoff-humano' end;
begin
  select * into c from public.mari_conversas where chatwoot_conversation_id = p_conversa_cw and canal = 'whatsapp'
   order by (funil_destino = 'teste_duplicada'), updated_at desc nulls last limit 1;
  if c.id is null then return jsonb_build_object('ok', false, 'erro', 'conversa não achada'); end if;
  tb := coalesce((public._bo_cfg('chatwoot_time_backoffice', '15102'::jsonb) #>> '{}')::int, 15102);

  if p_pedido in ('handoff_venda', 'handoff_humano', 'handoff_saida') then
    -- 21/11: handoff de venda/humano = o time passa a ser o dono NO NIOGEN (hoje isso só acontecia quando o Chatwoot avisava, pelo
    -- espelho, que a Mari pôs o time lá). Gravado pela porta, antes das ordens, para a situação já ser "com o time" e o projetor
    -- mandar o time ao Chatwoot de acordo com ela.
    if hand is not null and not coalesce(c.time_atribuido, false) then
      antes := public._porta_situacao(c.id, null::uuid);
      perform set_config('porta.aplicando', '1', true);
      update public.mari_conversas set time_atribuido = true where id = c.id;
      perform set_config('porta.aplicando', '', true);
      perform public._porta_anotar('mari:' || p_pedido, '0346', c.id, c.venda_id, antes,
        jsonb_build_object('ok', true, 'resumo', 'o time passa a ser o dono (handoff da Mari)'));
      select * into c from public.mari_conversas where id = c.id;
      feito := feito || 'time_dono'::text;
    end if;
    if public._porta_ordem(g, 1, 'mari_handoff', c, 'etiquetas',
         jsonb_build_object('add', to_jsonb(array_remove(array['handoff', hand], null)), 'remove', '[]'::jsonb)) then
      feito := feito || 'etiquetas'::text; end if;
    if p_nota is not null and public._porta_ordem(g, 2, 'mari_handoff', c, 'nota', jsonb_build_object('content', p_nota)) then
      feito := feito || 'nota'::text; end if;
    if hand is not null and c.chatwoot_time is null
       and public._porta_ordem(g, 3, 'mari_handoff', c, 'atribuir', jsonb_build_object('team_id', tb)) then
      feito := feito || 'time'::text; end if;
  elsif p_pedido = 'zerar' then
    if position(c.telefone in coalesce((select t.texto from public.config_mari_textos t where t.chave = 'telefones_teste'), '')) = 0 then
      return jsonb_build_object('ok', false, 'erro', 'zerar só em telefone de teste');
    end if;
    feito := feito || public._porta_projetar(c.id, 'mari_zerar', null, 'resolved');
  elsif p_pedido = 'interesse_futuro' then
    if public._porta_ordem(g, 1, 'mari_futuro', c, 'etiquetas', '{"add": ["interesse-futuro"], "remove": []}'::jsonb) then
      feito := feito || 'etiquetas'::text; end if;
    if p_nota is not null and public._porta_ordem(g, 2, 'mari_futuro', c, 'nota', jsonb_build_object('content', p_nota)) then
      feito := feito || 'nota'::text; end if;
  else
    return jsonb_build_object('ok', false, 'erro', 'pedido desconhecido: ' || coalesce(p_pedido, '-'));
  end if;
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'situacao', public._porta_situacao(c.id, null::uuid));
end $$;

revoke all on function public._mari_pode_falar_decide(text, text, text), public.mari_pode_falar(text, text, text), public.mari_chatwoot_pedir(text, text, text) from public, anon, authenticated;
grant execute on function public.mari_pode_falar(text, text, text), public.mari_chatwoot_pedir(text, text, text) to service_role;

commit;
