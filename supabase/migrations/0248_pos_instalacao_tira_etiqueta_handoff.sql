-- NIOGEN | supabase/migrations/0248_pos_instalacao_tira_etiqueta_handoff.sql | 16/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (16/11 ~21h): o Ivon respondeu "Tudo certo" à pós-instalação, mas o Chatwoot gravou só a nota de pós-venda e
-- o pedido de indicação não saiu. Causa: a 0243 tirou pessoa e time e deixou as etiquetas handoff-venda/handoff-humano; as
-- automações do Chatwoot 24389/24390 (INFRA: "reatribui o time sempre que uma conversa com handoff-venda/handoff-humano é
-- atualizada") puseram o time backoffice de volta quando ele escreveu; o gatilho mari_turnos_pos_instalacao viu o time (0226 M4)
-- e não respondeu.
-- Muda: (1) indicacao_tick — quando o instalado sai do time, as duas etiquetas de handoff saem antes (como no volta_mari).
--       (2) acerto do Ivon: tira as etiquetas (e a pos-venda), tira o time, trata o "Tudo certo" (linha → 'pediu') e manda o pedido
--           de indicação pela fila (_bo_mensagem 'indicacao_pedido'; janela de 24 h aberta pela fala dele).
-- indicacao_tick recriada a partir da 0244 (no ar). Regra 20: nenhum estado novo; tudo pela fila com turno de sistema e nota;
-- a linha segue a validade de sempre (pediu → encerrada em 48 h). Nada no mari_principal.
begin;

CREATE OR REPLACE FUNCTION public.indicacao_tick(p_agora timestamp with time zone DEFAULT now())
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  g     uuid;
  cfg   jsonb := public._ind_cfg();
  p     public.pos_instalacao;
  i     public.indicacoes;
  c     public.mari_conversas;
  v     public.vendas;
  ind   public.vendas;
  v_id  bigint;
  conta text := public._bo_cfg('chatwoot_conta', '195428') #>> '{}';
begin
  perform public._instaladas_fechar(p_agora);   -- 0244: roda mesmo com a indicação desligada
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
    -- 0243: instalou = o ciclo da venda fechou e o dono sai (regra do "dono da conversa", 0227). A 0226 (M4) esperava enquanto
    -- houvesse pessoa/time atribuído, mas nada tirava o time depois da instalação: a mensagem nunca saía e expirava em 3 dias
    -- (caso Ivon, 16/11). Agora só espera quem está falando de verdade (fala do time nas últimas 2 h); senão o dono sai, com nota.
    if coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null then
      if exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano'
                  and t.created_at > p_agora - interval '2 hours') then continue; end if;
      g := gen_random_uuid();
      -- 0248: as etiquetas de handoff saem ANTES do time — as automações 24389/24390 do Chatwoot reatribuem o time backoffice
      -- sempre que uma conversa com handoff-venda/handoff-humano é atualizada (a resposta do cliente trazia o time de volta).
      perform public._bo_enfileirar(g, 1, 'pos_instalacao', v.id, c, 'etiquetas',
        jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
      perform public._bo_enfileirar(g, 2, 'pos_instalacao', v.id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      perform public._bo_enfileirar(g, 3, 'pos_instalacao', v.id, c, 'desatribuir', jsonb_build_object('team_id', null));
      perform public._bo_enfileirar(g, 4, 'pos_instalacao', v.id, c, 'nota', jsonb_build_object('content',
        '🏠 NIOGEN · cliente instalado: a venda fechou e a conversa sai do time. A mensagem de pós-instalação (App Nio + indicação) '
        || 'sai agora pela automação. Se o cliente escrever, a nota de pós-venda avisa — responda pelo NIOGEN.'));
      update public.mari_conversas set humano_atribuido = false, time_atribuido = false, chatwoot_agente = null, chatwoot_time = null
       where id = c.id;
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (c.id, 'sistema', '[cliente instalado — a conversa saiu do time (pós-instalação, 0243); a mensagem de pós-instalação foi enfileirada]', false);
      select * into c from public.mari_conversas where id = c.id;
    end if;
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
    if coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null then continue; end if;   -- 0226 (M4)
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

-- ───────── acerto: Ivon da Costa Marques (conversa 103) ─────────
do $a$
declare
  c  public.mari_conversas;
  p  public.pos_instalacao;
  g  uuid := gen_random_uuid();
  tt public.mari_turnos;
begin
  select * into p from public.pos_instalacao where id = '1a9586e1-2117-4879-a47f-eac403e42166' and estado = 'enviada' for update;
  if p.id is null then raise notice 'Ivon: linha já não está em enviada — nada a fazer'; return; end if;
  select * into c from public.mari_conversas where id = p.conversa_id for update;
  select * into tt from public.mari_turnos where conversa_id = c.id and papel = 'lead' order by created_at desc limit 1;
  perform public._bo_enfileirar(g, 1, 'pos_instalacao', p.venda_id, c, 'etiquetas',
    jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('handoff-venda', 'handoff-humano', 'pos-venda')));
  perform public._bo_enfileirar(g, 2, 'pos_instalacao', p.venda_id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
  perform public._bo_enfileirar(g, 3, 'pos_instalacao', p.venda_id, c, 'desatribuir', jsonb_build_object('team_id', null));
  perform public._bo_enfileirar(g, 4, 'pos_instalacao', p.venda_id, c, 'nota', jsonb_build_object('content',
    '🏠 NIOGEN · a resposta "' || left(coalesce(tt.texto, ''), 60) || '" foi tratada pela automação: pedido de indicação enviado. '
    || 'A nota de pós-venda acima não precisa de ação (o time voltou por causa das etiquetas de handoff — corrigido).'));
  update public.mari_conversas set humano_atribuido = false, time_atribuido = false, chatwoot_agente = null, chatwoot_time = null,
         dispensada_em = now()
   where id = c.id;
  select * into c from public.mari_conversas where id = c.id;
  update public.pos_instalacao set estado = 'pediu', respondeu_em = coalesce(tt.created_at, now()), pediu_em = now(),
         resposta = left(coalesce(tt.texto, ''), 300), tratado_em = now()
   where id = p.id;
  perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_pedido', p.venda_id, c, 'indicacao_pedido', '{}'::jsonb);
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[resposta da pós-instalação tratada depois (0248): o time tinha voltado pelas etiquetas de handoff; pedido de indicação enviado]', false);
end $a$;

commit;
