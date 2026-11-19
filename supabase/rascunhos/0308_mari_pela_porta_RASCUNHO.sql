-- NIOGEN | supabase/rascunhos/0308_mari_pela_porta_RASCUNHO.sql | 19/11/2026 02h45 — Claude Code (Opus 5.5), tarefa niogen-passo4-madrugada
-- ⚠️ RASCUNHO — NÃO APLICAR. Não está em supabase/migrations de propósito. De manhã, com o Ricardo: copiar para supabase/migrations
-- com o próximo número livre, escrever o cenário (a Mari pergunta ao banco e não mexe no Chatwoot), passar o portão e aplicar pela
-- trava — e SÓ DEPOIS subir a Mari nova pelo portão da Mari (n8n/rascunhos/passo4_191126/).
-- Fase 2, passo 4, lado do banco para a Mari e a cadência do n8n (docs/DIAGNOSTICO_fechamento_porta_181126_1503.md §6):
--  (1) mari_pode_falar(conversa do Chatwoot, para, passo): a pergunta "pode falar?" que troca os guards 2h (Mari) e 6h (cadência).
--      Responde pela SITUAÇÃO do lead (config_situacao) e pelo NIOGEN, nunca pelo Chatwoot ao vivo. Sem resposta, o n8n não fala.
--      Mesmas regras dos guards de hoje (n02h_guard_humano.js e c06_guard.js), agora lidas do banco:
--        resposta (2h): Não contatar → cala · pessoa do time dona → cala · time dono (fora a janela pós-handoff da venda) → cala ·
--                       Saída / Cliente Nio / Instalada → segue para o 3a (o mari_entrada já decide a resposta curta, o App Nio, a
--                       pós-instalação) · resto → pode.
--        lembrete (6h): aviso da venda (INSTALACAO, VESPERA, CARTAO, CARTAO2, BIO1, BIOVOLTA) → sai sempre, só Não contatar e Saída
--                       barram (regra de ouro 6) · escada → só em "Mari atendendo" sem dono; senão para a escada (parar = true).
--  (2) mari_chatwoot_pedir(conversa do Chatwoot, pedido, nota): o que hoje os nós 2p/2u, 9e/9f/9h e 9f da cadência fazem direto no
--      Chatwoot vira ORDEM NA FILA pela porta (_porta_ordem, que não duplica na mesma transação) e o projetor acerta o resto:
--        'handoff_venda' | 'handoff_humano' → etiqueta handoff + handoff-venda/-humano, nota com o briefing, time backoffice
--        'handoff_saida' → etiqueta handoff e nota (a Saída em si já vem do mari_handoff pela porta)
--        'zerar' (só telefone de teste) → tira as etiquetas de destino e resolve (o que o 2p "labels: []" + 2u faziam)
--        'interesse_futuro' → etiqueta interesse-futuro + nota (cadência 9f/9g)
--      Etiqueta sempre como add/remove, NUNCA a lista inteira (o 2p e o 9e de hoje gravam a lista inteira e apagam as outras).
-- Regra 20: (1) não cria situação; (2) sem estado novo; (3) quem grava é a porta (_porta_ordem); (4) fonte única: a situação no banco
-- em vez do Chatwoot ao vivo; (5) conferência: v_projetor_sombra_divergencias (0307) passa a mostrar as ordens da Mari, que hoje
-- não aparecem (a Mari escreve no Chatwoot por fora da fila).
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
  c public.mari_conversas; g uuid := gen_random_uuid(); feito text[] := '{}'; tb int;
  hand text := case p_pedido when 'handoff_venda' then 'handoff-venda' when 'handoff_humano' then 'handoff-humano' end;
begin
  select * into c from public.mari_conversas where chatwoot_conversation_id = p_conversa_cw and canal = 'whatsapp'
   order by (funil_destino = 'teste_duplicada'), updated_at desc nulls last limit 1;
  if c.id is null then return jsonb_build_object('ok', false, 'erro', 'conversa não achada'); end if;
  tb := coalesce((public._bo_cfg('chatwoot_time_backoffice', '15102'::jsonb) #>> '{}')::int, 15102);

  if p_pedido in ('handoff_venda', 'handoff_humano', 'handoff_saida') then
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
-- Conferido na cópia local (19/11 ~02h55): compila e responde; nomes corrigidos (updated_at, config_mari_textos.telefones_teste,
-- _bo_cfg). Falta conferir: se o mari_handoff__nucleo já põe o time pela porta — então o pedido handoff_* não manda atribuir.
