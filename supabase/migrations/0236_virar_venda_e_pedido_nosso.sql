-- NIOGEN | supabase/migrations/0236_virar_venda_e_pedido_nosso.sql | 16/11/2026 — Claude Code / Opus 5.5
-- Pedido do Ricardo (16/11, caso Lígia, conversa 117 — "O pedido foi eu que criei e não consegui gravar: 12177154" → "Sim, fazer agora").
-- Dois buracos que travaram a venda:
--   (A) A venda só nascia no handoff 'dados_completos' da Mari (mari_handoff). Lead conduzido à mão pelo time (crédito pela
--       ficha/extensão) nunca virava venda — e a OS só se grava numa venda (backoffice_momento: "Este botão precisa de uma venda").
--       → RPC nova lead_virar_venda(p_conversa): admin/backoffice cria a venda pelo MESMO caminho do handoff (mesmas travas:
--       elegibilidade, área, plano, nome, endereço, duplicidade no NIOGEN). Recusa → exceção com o motivo, nada gravado.
--   (B) A checagem de duplicidade (mari_dup_gravar) achou o pedido que o próprio time acabara de abrir e marcou o lead como
--       "já é cliente Nio" (Saída). → Se o time já trabalhou o pedido deste lead no portal (crédito consultado pela tela ou pela
--       extensão, ou venda com nº de pedido), "pedido em andamento" é o NOSSO: grava 'nao' (não sai do funil), registra
--       'pedido_nosso' na consulta e deixa um turno de sistema dizendo para gravar o nº na venda.
-- Regra 20: (1) a venda nasce em 0_qualificado — etapa/status/vez/prazo da escada (Qualificado · fazer pedido, vez do time) ·
-- (2) saída: o time grava o pedido/OS ou dá Saída — prazo já contado pela escada · (3) estado muda só por função, com autor
-- (auth.uid() no evento e no turno) · (4) pedido e OS continuam com fonte na Nio (o nº vem do portal) · (5) sem número novo:
-- o retrato conta vendas pelo mesmo v_leads; a consulta 'pedido_nosso' fica no operador_consultas.
-- Medição (7 dias): vendas com eventos_venda.tipo = 'virou_venda_niogen' que chegaram a OS; consultas de duplicidade com
-- resultado 'pedido_nosso' (deviam ser só pedidos do time) e leads em ja_cliente_nio com crédito da tela antes (→ 0).

-- (A) ------------------------------------------------------------------------------------------------------------------
create or replace function public.lead_virar_venda(p_conversa uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c public.mari_conversas;
  r jsonb;
  quem text;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null then
    return jsonb_build_object('ok', true, 'venda_id', c.venda_id, 'repetido', true);
  end if;
  if coalesce(c.funil_destino, 'em_andamento') not in ('em_andamento') then
    raise exception 'O lead está em Saída (%). Reabra antes de virar venda.', c.funil_destino;
  end if;
  quem := coalesce((select u.nome from public.usuarios u where u.id = auth.uid()), 'alguém do time');
  -- mari_handoff só cria a venda com a conversa 'ativo'; handoff anterior sem venda (pedido de humano, crédito) volta a 'ativo'
  if c.status <> 'ativo' then
    update public.mari_conversas set status = 'ativo' where id = c.id;
  end if;
  r := public.mari_handoff(c.id, 'dados_completos',
         jsonb_build_object('briefing', 'Venda aberta no NIOGEN por ' || quem || ' (lead conduzido pelo time).'));
  if not coalesce((r ->> 'ok')::boolean, false) or r ->> 'venda_id' is null then
    raise exception 'A venda não foi criada: %.', coalesce(r ->> 'motivo_recusa', 'motivo desconhecido');
  end if;
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values ((r ->> 'venda_id')::uuid, 'virou_venda_niogen', jsonb_build_object('conversa_id', c.id, 'por', quem), auth.uid());
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[venda aberta no NIOGEN por ' || quem || ']', false);
  return jsonb_build_object('ok', true, 'venda_id', r ->> 'venda_id');
end $$;

revoke all on function public.lead_virar_venda(uuid) from public, anon;
grant execute on function public.lead_virar_venda(uuid) to authenticated;

-- (B) ------------------------------------------------------------------------------------------------------------------
create or replace function public.mari_dup_gravar(p_conversa uuid, p_saida jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_op text := p_saida->>'resultado'; v text; c record; v_nosso boolean := false; v_res text;
begin
  if coalesce(p_saida->>'retry', '') = 'true' then
    update public.mari_conversas set nio_pedido_aberto_em = null, dup_consultas = greatest(dup_consultas - 1, 0)
     where id = p_conversa and nio_pedido_aberto is null;
    return jsonb_build_object('ok', true, 'resultado', 'de_volta_na_fila');
  end if;
  -- 0236: o time já mexeu no pedido deste lead no portal → o "pedido em andamento" é o nosso
  if v_op = 'pedido_em_andamento' then
    select exists (select 1 from public.operador_consultas o
                    where o.conversa_id = p_conversa and o.tipo = 'credito' and o.origem in ('tela', 'extensao')
                      and o.criado_em > now() - interval '7 days')
        or exists (select 1 from public.mari_conversas mc join public.vendas vv on vv.id = mc.venda_id
                    where mc.id = p_conversa and (nullif(btrim(vv.nio_pedido), '') is not null or nullif(btrim(vv.nio_os), '') is not null))
      into v_nosso;
  end if;
  v := case when v_nosso then 'nao'
            when v_op = 'pedido_em_andamento' then 'sim' when v_op = 'sem_pedido_em_andamento' then 'nao' end;
  v_res := case when v_nosso then 'pedido_nosso' else coalesce(v_op, 'erro') end;
  update public.mari_conversas set nio_pedido_aberto = v, nio_pedido_aberto_em = now()
   where id = p_conversa returning id, venda_id into c;
  if c.id is null then return jsonb_build_object('ok', false, 'motivo', 'conversa não encontrada'); end if;
  insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cpf_mascara, resultado, detalhe, ms)
  values ('duplicidade', 'mari', p_conversa, c.venda_id, p_saida->>'cpf_mascara', v_res,
          jsonb_strip_nulls(jsonb_build_object('motivo', p_saida->>'motivo', 'popup', p_saida->'popup'->>'texto',
                                               'etapa_parada', p_saida->'etapa_parada', 'cache', p_saida->'cache',
                                               'portal', case when v_nosso then v_op end)),
          nullif(p_saida->>'ms', '')::int);
  if v_nosso then
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (p_conversa, 'sistema', '[o portal já tem pedido em andamento para este CPF — é o pedido aberto pelo time: '
            || case when c.venda_id is null then 'vire venda na ficha e grave o nº do pedido]' else 'grave o nº do pedido na venda]' end, false);
  end if;
  return jsonb_build_object('ok', true, 'resultado', v_res, 'pedido_aberto', v);
end $$;
