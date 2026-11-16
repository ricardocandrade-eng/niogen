-- NIOGEN | supabase/migrations/0244_instalada_fecha_na_vez_do_cliente.sql | 16/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (16/11 ~19h30, "a conversa deveria continuar aberta no Niogen?" → "Sim, faça"): conversa de cliente
-- instalado ficava Aberta para sempre — a _conversas_volta_mari e o gatilho mari_turnos_refechar (0199) pulam "instalada" de
-- propósito, e nada mais fecha. Caso Ivon (conversa 103), depois da 0243.
-- Regra (sistema fechado: aberta = o time tem algo a fazer): conversa com destino Instalada e venda instalada é RESOLVIDA
-- quando a vez é do cliente —
--   · a última fala (fora sistema) é nossa (Mari/automação ou time) há 5 min ou mais;
--   · com a etiqueta pos-venda (reclamação, resposta não entendida, chave Pix), só fecha se a última fala é do TIME e tem 2 h
--     (a fala automática "já avisei o nosso time" não fecha um problema);
--   · ninguém atribuído, nada a fazer na fila (resolver pendente) e a mensagem de pós-instalação já saiu (linha não 'agendada').
-- O cliente escreve → o Chatwoot reabre; as respostas da indicação e a nota de pós-venda seguem como antes (não dependem do
-- status). Roda no indicacao_tick (n8n indicacao_rotina, a cada 10 min), antes da chave "ligado".
-- indicacao_tick recriada a partir da 0243 (no ar). Regra 20: nenhum estado novo; o Chatwoot muda pela fila (ação 'resolver',
-- momento 'instalada_fechar') com turno de sistema; não muda a vez de ninguém. Nada no mari_principal.
begin;

create or replace function public._instaladas_fechar(p_agora timestamptz default now()) returns int
language plpgsql security definer set search_path = public as $$
declare
  c    public.mari_conversas;
  ult  record;
  n    int := 0;
begin
  for c in
    select m.* from public.mari_conversas m
      join public.vendas v on v.id = m.venda_id
     where m.canal = 'whatsapp' and m.chatwoot_conversation_id is not null
       and coalesce(m.chatwoot_status, 'open') = 'open'
       and m.funil_destino = 'instalada'
       and v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')
       and m.chatwoot_agente is null and not coalesce(m.humano_atribuido, false) and not coalesce(m.time_atribuido, false)
       and not exists (select 1 from public.pos_instalacao p where p.venda_id = v.id and p.estado = 'agendada')
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
     limit 20
     for update of m skip locked
  loop
    select t.papel, t.created_at into ult from public.mari_turnos t
     where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano') order by t.created_at desc limit 1;
    if ult.papel is null or ult.papel = 'lead' then continue; end if;                       -- a vez é nossa: fica aberta
    if ult.created_at > p_agora - interval '5 minutes' then continue; end if;               -- deixa a mensagem chegar
    if 'pos-venda' = any(coalesce(c.chatwoot_etiquetas, '{}'))
       and (ult.papel <> 'humano' or ult.created_at > p_agora - interval '2 hours') then continue; end if;   -- problema sem o time
    perform public._bo_enfileirar(gen_random_uuid(), 1, 'instalada_fechar', c.venda_id, c, 'resolver',
                                  jsonb_build_object('status', 'resolved'));
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[cliente instalado e a vez é dele — conversa resolvida no Chatwoot (0244); se ele escrever, reabre]', false);
    n := n + 1;
  end loop;
  return n;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_instaladas_fechar', sqlerrm);
  return n;
end $$;
revoke all on function public._instaladas_fechar(timestamptz) from public, anon, authenticated;

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
      perform public._bo_enfileirar(g, 1, 'pos_instalacao', v.id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      perform public._bo_enfileirar(g, 2, 'pos_instalacao', v.id, c, 'desatribuir', jsonb_build_object('team_id', null));
      perform public._bo_enfileirar(g, 3, 'pos_instalacao', v.id, c, 'nota', jsonb_build_object('content',
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

commit;
