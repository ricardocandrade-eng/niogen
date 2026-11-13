-- NIOGEN | supabase/migrations/0178_indicacao_mesma_conversa.sql | 13/11/2026 — Claude Code (Fable 5.2)
-- Teste real com o número do Ricardo (13/11, conversa nº 91 do Chatwoot): a rotina abriu a conversa e o template saiu, mas
--   1. a resposta do indicado chegou com o telefone COM o 9 (como está no contato que criamos no Chatwoot) e a conversa tinha
--      sido gravada SEM o 9 → a Mari abriu uma conversa nova, sem o histórico do primeiro contato (a rede de segurança da 0176
--      religou a indicação e fechou a conversa órfã, mas o contexto se perdeu);
--   2. o contato sem nome nasceu como "Indicação de Maria" e a Mari cumprimentou "Oi, Indicação".
-- O que muda: só indicacao_tick (nome do contato) e indicacao_abertura_resultado (telefone). O resto é idêntico à 0176.

create or replace function public.indicacao_tick(p_agora timestamptz default now())
returns setof jsonb language plpgsql security definer set search_path = public as $$
declare
  cfg   jsonb := public._ind_cfg();
  p     public.pos_instalacao;
  i     public.indicacoes;
  c     public.mari_conversas;
  v     public.vendas;
  ind   public.vendas;
  v_id  bigint;
  conta text := public._bo_cfg('chatwoot_conta', '195428') #>> '{}';
begin
  if not coalesce((cfg ->> 'ligado')::boolean, false) then return; end if;

  -- validade
  update public.pos_instalacao set estado = 'sem_resposta', encerrada_em = p_agora
   where estado = 'enviada' and enviada_em < p_agora - make_interval(days => coalesce((cfg ->> 'validade_resposta_dias')::int, 7));
  update public.pos_instalacao set estado = 'encerrada', encerrada_em = p_agora
   where estado = 'pediu' and pediu_em < p_agora - make_interval(hours => coalesce((cfg ->> 'validade_pedido_horas')::int, 48));

  -- (1) mensagem de pós-instalação
  for p in select * from public.pos_instalacao where estado = 'agendada' and enviar_em <= p_agora order by enviar_em limit 20 for update skip locked loop
    select * into v from public.vendas where id = p.venda_id;
    if v.status not in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')
       or v.instalado_em < p_agora - make_interval(days => coalesce((cfg ->> 'janela_instalacao_dias')::int, 3)) then
      update public.pos_instalacao set estado = 'expirada', encerrada_em = p_agora where id = p.id;
      continue;
    end if;
    select * into c from public.mari_conversas
     where id = coalesce(p.conversa_id, (select m.id from public.mari_conversas m where m.venda_id = v.id order by m.updated_at desc limit 1));
    if c.id is null or coalesce(c.canal, '') <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' then
      update public.pos_instalacao set estado = 'sem_conversa', encerrada_em = p_agora where id = p.id;
      continue;
    end if;
    if coalesce(c.nao_contatar, false) then
      update public.pos_instalacao set estado = 'encerrada', encerrada_em = p_agora, resposta = 'cliente pediu para não ser contatado' where id = p.id;
      continue;
    end if;
    if not public.mari_no_horario(p_agora, coalesce(v.cidade, c.cidade)) then continue; end if;
    v_id := public._ind_template(c, v.id, 'pos_instalacao', 'nio_pos_instalacao',
                                 jsonb_build_array(coalesce(public._ind_primeiro_nome(coalesce(v.cliente_nome, c.nome_contato)), 'tudo bem')));
    if v_id is null then continue; end if;   -- template ainda não aprovado: tenta na próxima volta
    update public.pos_instalacao set estado = 'enviada', enviada_em = p_agora, conversa_id = c.id where id = p.id;
  end loop;

  -- (2) insistir uma vez com quem recebeu o pedido e ficou em silêncio (só com a janela de 24 h aberta)
  for p in select * from public.pos_instalacao
            where estado = 'pediu' and insistencias = 0
              and pediu_em <= p_agora - make_interval(mins => coalesce((cfg ->> 'insistir_apos_min')::int, 120))
            limit 20 for update skip locked loop
    select * into c from public.mari_conversas where id = p.conversa_id;
    if c.id is null or coalesce(c.nao_contatar, false) or c.ultima_msg_lead_at is null
       or p_agora >= c.ultima_msg_lead_at + interval '23 hours' then
      update public.pos_instalacao set insistencias = 1 where id = p.id;   -- janela fechou: não insiste por template
      continue;
    end if;
    if not public.mari_no_horario(p_agora, c.cidade) then continue; end if;
    perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_insistir', p.venda_id, c, 'indicacao_insistir', '{}'::jsonb);
    update public.pos_instalacao set insistencias = 1, insistiu_em = p_agora where id = p.id;
  end loop;

  -- (3) prêmio previsto e sem chave Pix: pede a chave a quem indicou (template)
  for i in select * from public.indicacoes where premio_status = 'previsto' and pix_chave is null and pix_pedido_em is null
            limit 20 for update skip locked loop
    select * into c from public.mari_conversas where id = i.indicador_conversa_id;
    select * into ind from public.vendas where id = i.indicador_venda_id;
    if c.id is null or not public.mari_no_horario(p_agora, coalesce(ind.cidade, c.cidade)) then continue; end if;
    v_id := public._ind_template(c, i.indicador_venda_id, 'indicacao_premio', 'nio_indicacao_premio',
              jsonb_build_array(coalesce(public._ind_primeiro_nome(coalesce(ind.cliente_nome, c.nome_contato)), 'tudo bem'),
                                coalesce(public._ind_primeiro_nome(coalesce(i.indicado_nome,
                                  (select vv.cliente_nome from public.vendas vv where vv.id = i.venda_id))), 'Quem você indicou')));
    if v_id is null then continue; end if;
    update public.indicacoes set pix_pedido_em = p_agora where id = i.id;
  end loop;

  -- (4) indicados a abrir no Chatwoot (a rotina cria contato + conversa e chama indicacao_abertura_resultado)
  if not coalesce((cfg ->> 'abrir_conversa')::boolean, false)
     or not exists (select 1 from public.config_templates_waba where nome = 'nio_indicacao_contato' and status = 'APPROVED') then
    return;
  end if;
  for i in select * from public.indicacoes x
            where x.estado = 'recebida' and x.tentativas < 3
              and (x.tentativa_em is null or x.tentativa_em < p_agora - interval '30 minutes')
            order by x.criado_em limit 10 for update skip locked loop
    select * into ind from public.vendas where id = i.indicador_venda_id;
    if not public.mari_no_horario(p_agora, ind.cidade) then continue; end if;
    update public.indicacoes set tentativas = tentativas + 1, tentativa_em = p_agora where id = i.id;
    return next jsonb_build_object(
      'id', i.id,
      -- 0178: sem nome, o contato nasce com o telefone (como todo contato novo do WhatsApp) — a Mari não chama ninguém de "Indicação"
      'nome', coalesce(i.indicado_nome, '+' || i.indicado_telefone),
      'telefone', '+' || i.indicado_telefone,
      'inbox_id', coalesce((cfg ->> 'inbox_id')::int, 153431),
      'base', 'https://app.chatwoot.com/api/v1/accounts/' || conta);
  end loop;
  return;
end $$;
revoke all on function public.indicacao_tick(timestamptz) from public, anon, authenticated;
grant execute on function public.indicacao_tick(timestamptz) to service_role;

create or replace function public.indicacao_abertura_resultado(p_id uuid, p_ok boolean, p_chatwoot_conversation_id text default null, p_erro text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  i    public.indicacoes;
  c    public.mari_conversas;
  ind  public.vendas;
  v_cw text := nullif(btrim(coalesce(p_chatwoot_conversation_id, '')), '');
  v_tel text;
  v_id bigint;
begin
  select * into i from public.indicacoes where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'erro', 'indicação inexistente'); end if;
  if i.estado <> 'recebida' then return jsonb_build_object('ok', true, 'registrado', 'já tratada'); end if;
  if not coalesce(p_ok, false) or v_cw is null then
    update public.indicacoes set motivo = left(coalesce(p_erro, 'sem detalhe'), 300),
           estado = case when tentativas >= 3 then 'erro' else estado end where id = p_id;
    if i.tentativas >= 3 then
      insert into public.mari_erros (no_n8n, mensagem, payload)
      values ('indicacao_rotina', 'não abri a conversa do indicado (3×): ' || left(coalesce(p_erro, ''), 300), jsonb_build_object('indicacao_id', p_id));
    end if;
    return jsonb_build_object('ok', true, 'registrado', 'erro');
  end if;

  select * into ind from public.vendas where id = i.indicador_venda_id;
  -- 0178: o telefone fica como está no contato do Chatwoot (com o 9): é assim que a resposta do indicado chega à mari_entrada,
  -- e ela cai na MESMA conversa (com o histórico do primeiro contato). O formato sem o 9 abria uma conversa nova.
  v_tel := i.indicado_telefone;
  select * into c from public.mari_conversas m
   where m.canal = 'whatsapp' and m.status in ('ativo', 'handoff_realizado')
     and (m.chatwoot_conversation_id = v_cw or public._tel_chave(m.telefone) = i.tel_chave)
   order by (m.chatwoot_conversation_id = v_cw) desc limit 1;
  if c.id is null then
    insert into public.mari_conversas (telefone, nome_contato, canal, origem, chatwoot_conversation_id, cadencia_passo, cadencia_passo_em)
    values (v_tel, i.indicado_nome, 'whatsapp', 'indicacao', v_cw, 'P1', now())
    returning * into c;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[lead indicado por ' || coalesce(nullif(btrim(ind.cliente_nome), ''), 'um cliente') ||
            ' (cliente já instalado) — a Mari fez o primeiro contato por template citando quem indicou]', false);
    v_id := public._ind_template(c, null, 'indicacao', 'nio_indicacao_contato',
              jsonb_build_array(coalesce(public._ind_primeiro_nome(i.indicado_nome), 'tudo bem'),
                                coalesce(public._ind_primeiro_nome(ind.cliente_nome), 'Um cliente nosso')));
    -- conta como o P1 da cadência: ela segue com D7 e D15 sozinha, sem repetir o primeiro contato
    insert into public.contatos_cliente (conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
    values (c.id, c.telefone, 'whatsapp', 'saida', 'mari', now(), 'P1', 'ativo', 'Indicação · primeiro contato (template nio_indicacao_contato)');
  end if;
  update public.indicacoes set estado = 'contatada', conversa_id = c.id, contatada_em = now(), motivo = null where id = p_id;
  return jsonb_build_object('ok', true, 'registrado', 'contatada', 'conversa_id', c.id, 'acao_id', v_id);
end $$;
revoke all on function public.indicacao_abertura_resultado(uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.indicacao_abertura_resultado(uuid, boolean, text, text) to service_role;
