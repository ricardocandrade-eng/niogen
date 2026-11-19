-- NIOGEN | supabase/migrations/0308_varredura_indicacao_7_60.sql | 19/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 19/11: "Baixa o prazo da varredura para 7 dias" → (alerta: o mesmo varredura_dias também é o intervalo entre pedidos, o
-- cliente receberia o modelo de marketing toda semana) → "Sim, 7 e 60".
-- A varredura da base instalada (0303) passa a ter dois prazos em config_regras.indicacao:
--   varredura_primeira_dias = 7  → o 1º pedido sai 7 dias depois da instalação e 7 dias depois do pós-instalação (que já pede indicação);
--   varredura_dias          = 60 → a repetição para o mesmo cliente (pedido anterior, respondido ou pulado) só a cada 60 dias.
-- Continua: só com nio_indicacao_base APPROVED, lote 10, 9h–21h, espera 2 h se o time falou, nunca luto/urgência/não contatar.
-- Só troca indicacao_tick (o resto da 0303 fica igual). Cenário X37 ganhou a parte 7/60.
begin;

update public.config_regras
   set valor = valor || jsonb_build_object('varredura_primeira_dias', 7, 'varredura_dias', 60)
 where chave = 'indicacao';

CREATE OR REPLACE FUNCTION public.indicacao_tick(p_agora timestamp with time zone DEFAULT now())
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  perform public._saidas_fechar(p_agora);       -- 0249: Saída aberta sem ninguém com o que fazer
  perform public._porta_prazos(p_agora);        -- 0266: prazos do time pela porta (C10 fecha com dono guardado · C4 handoff sem resposta)
  if not coalesce((cfg ->> 'ligado')::boolean, false) then return; end if;

  -- validade
  update public.pos_instalacao set estado = 'sem_resposta', encerrada_em = p_agora
   where estado = 'enviada' and enviada_em < p_agora - make_interval(days => coalesce((cfg ->> 'validade_resposta_dias')::int, 7));
  update public.pos_instalacao set estado = 'encerrada', encerrada_em = p_agora
   where estado = 'pediu' and pediu_em < p_agora - make_interval(hours => coalesce((cfg ->> 'validade_pedido_horas')::int, 48));

  update public.indicacao_pedidos set estado = 'sem_resposta', encerrada_em = p_agora   -- 0303
   where estado = 'pediu' and pedido_em < p_agora - make_interval(days => coalesce((cfg ->> 'validade_resposta_dias')::int, 7));

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

  -- (2b) 0303: varredura da base instalada — 1 toque por cliente pedindo indicação (template nio_indicacao_base;
  -- 0308 (Ricardo, 19/11: "7 e 60"): o 1º toque sai varredura_primeira_dias (7) depois da instalação e do pós-instalação; a repetição
  -- para o mesmo cliente só a cada varredura_dias (60);
  -- só a Meta aprova: até lá, nada sai). Quem não pode receber vira 'pulado' para a varredura não olhar de novo.
  if coalesce((cfg ->> 'varredura_ligada')::boolean, false)
     and exists (select 1 from public.config_templates_waba where nome = 'nio_indicacao_base' and status = 'APPROVED') then
    for v in select vv.* from public.vendas vv
              where vv.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') and vv.cancelada_apos_instalar_em is null
                and vv.instalado_em <= p_agora - make_interval(days => coalesce((cfg ->> 'varredura_primeira_dias')::int, coalesce((cfg ->> 'varredura_dias')::int, 60)))
                and not exists (select 1 from public.indicacao_pedidos x where x.venda_id = vv.id
                                 and x.pedido_em > p_agora - make_interval(days => coalesce((cfg ->> 'varredura_dias')::int, 60)))
                and not exists (select 1 from public.pos_instalacao pp where pp.venda_id = vv.id
                                 and coalesce(pp.pediu_em, pp.enviada_em) > p_agora - make_interval(days => coalesce((cfg ->> 'varredura_primeira_dias')::int, coalesce((cfg ->> 'varredura_dias')::int, 60))))
              order by vv.instalado_em limit coalesce((cfg ->> 'varredura_lote')::int, 10) loop
      select * into c from public.mari_conversas m where m.venda_id = v.id and m.canal = 'whatsapp' order by m.updated_at desc limit 1;
      if c.id is null or coalesce(c.chatwoot_conversation_id, '') = '' or public._ind_pode_pedir(c) is not null then
        insert into public.indicacao_pedidos (conversa_id, venda_id, motivo, estado, encerrada_em, resposta)
        values (c.id, v.id, 'varredura', 'pulado', p_agora, coalesce(public._ind_pode_pedir(c), 'sem conversa no Chatwoot'));
        continue;
      end if;
      if not public.mari_no_horario(p_agora, coalesce(v.cidade, c.cidade)) then continue; end if;
      if exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano'
                  and t.created_at > p_agora - interval '2 hours') then continue; end if;   -- alguém do time falando: espera
      v_id := public._ind_template(c, v.id, 'indicacao_varredura', 'nio_indicacao_base',
                                   jsonb_build_array(coalesce(public._ind_primeiro_nome(coalesce(v.cliente_nome, c.nome_contato)), 'tudo bem')));
      if v_id is null then continue; end if;
      insert into public.indicacao_pedidos (conversa_id, venda_id, motivo) values (c.id, v.id, 'varredura');
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (c.id, 'sistema', '[varredura da base instalada: a Mari pediu uma indicação (template nio_indicacao_base, 0303)]', false);
    end loop;
  end if;

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
end $function$;

commit;
