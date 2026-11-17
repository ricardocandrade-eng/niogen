-- NIOGEN | supabase/migrations/0249_saida_fecha_sem_corrida.sql | 16/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (16/11 ~21h40, "Carlos Alberto Da Silva - Não era pra ter 'Resolvido' no Niogen?" → "Sim, corrija"):
-- conversa 141, destino Fora da área. Resolvida 21h19 pelo destino; o cliente escreveu ("Jardim do lago") e o Chatwoot reabriu;
-- a Mari respondeu a despedida 21h20, mas o gatilho mari_turnos_refechar (0199) exigia chatwoot_status <> 'resolved' e o espelho
-- ainda dizia "resolved" (o aviso de reabertura chega segundos depois) → não refechou; depois "Sim"/"Ok" do cliente (fala do
-- cliente não fecha nada) → Aberta, sem dono e sem ninguém com o que fazer.
-- Muda:
--   (1) _conversa_refechar: sem a condição do chatwoot_status (resolver de novo é inofensivo; continua 1 resolver na fila por vez).
--   (2) _saidas_fechar (novo, chamado no indicacao_tick, a cada 10 min): conversa em Saída (destino fora em_andamento/instalada,
--       venda nenhuma ou em Saída, sem pessoa nem time, fora suporte_nio), Aberta, sem ação na fila, é resolvida quando
--       a) a última fala é nossa há >= 5 min; ou
--       b) tudo o que o cliente mandou depois da nossa última fala é só confirmação/despedida curta ("ok", "sim", "obrigado",
--          "valeu", emoji…), sem mídia, e a última há >= 5 min. Qualquer outra fala do cliente deixa aberta para o time.
-- indicacao_tick recriada a partir da 0248 (no ar). Regra 20: nenhum estado novo; o Chatwoot muda pela fila ('resolver', momento
-- 'saida_fechar') com turno de sistema. Nada no mari_principal.
begin;

CREATE OR REPLACE FUNCTION public._conversa_refechar()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  c public.mari_conversas;
begin
  select * into c from public.mari_conversas where id = new.conversa_id;
  if c.id is null or c.canal <> 'whatsapp' or c.chatwoot_conversation_id is null then return null; end if;
  -- silenciada: o cliente escreveu e o Chatwoot reabriu → adia de novo (não volta para o Live; fica em Conversas › Todas)
  if new.papel = 'lead' and coalesce(c.quadro_encerrada_motivo, '') = 'suporte_nio' then
    if not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'resolver'
                    and a.status in ('pendente', 'executando') and a.payload ->> 'status' = 'snoozed') then
      perform public._bo_enfileirar(gen_random_uuid(), 1, 'silenciar', null, c, 'resolver', jsonb_build_object('status', 'snoozed'),
                                    now() + interval '1 minute');
    end if;
    return null;
  end if;
  -- Saída (fora instalada, que tem o pós-venda) e nós respondemos: resolve de novo
  if new.papel in ('mari', 'humano')
     and coalesce(c.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada')
     and coalesce(c.quadro_encerrada_motivo, '') <> 'suporte_nio'
     -- 0249: não olha o chatwoot_status do espelho — o aviso de reabertura do Chatwoot pode chegar DEPOIS da nossa resposta
     -- (caso Carlos Alberto, 16/11 21h20: resolvida 21h19, cliente escreveu, Mari respondeu, espelho ainda "resolved" → ficou aberta)
     and c.chatwoot_agente is null and not coalesce(c.humano_atribuido, false)
     and (c.venda_id is null or exists (select 1 from public.vendas v where v.id = c.venda_id and v.status = 'saida'))
     and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'resolver'
                      and a.status in ('pendente', 'executando')) then
    perform public._bo_enfileirar(gen_random_uuid(), 1, 'refechar', c.venda_id, c, 'resolver', jsonb_build_object('status', 'resolved'),
                                  now() + interval '2 minutes');
  end if;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_conversa_refechar', sqlerrm);
  return null;
end;
$$
;

create or replace function public._saida_so_confirmacao(p_texto text) returns boolean language sql immutable as $f$
  select length(public._ind_norm(p_texto)) <= 40 and (public._ind_norm(p_texto) = ''
         or public._ind_norm(p_texto) ~ ('^((ok|okay|okk+|oks|sim|s|ss|blz|beleza|certo|ta|ta bom|ta certo|ta otimo|entendi|entendido|'
            || 'obrigad[oa]|obg|obgd[oa]?|brigad[oa]|muito obrigad[oa]|valeu|vlw|tchau|de nada|show|top|joia|perfeito|combinado|'
            || 'uhum|aham|ah|ahh|kk+|rs+|tudo bem|tudo certo|boa noite|bom dia|boa tarde|ate mais|abraco|amem|deus abencoe|'
            || 'que pena|pena|poxa|ah que pena|tranquilo|sem problema|fica pra proxima|grato|grata|agradeco)( |$))+$'))
$f$;

create or replace function public._saidas_fechar(p_agora timestamptz default now()) returns int
language plpgsql security definer set search_path = public as $$
declare
  c     public.mari_conversas;
  ult   record;
  nosso timestamptz;
  n     int := 0;
begin
  for c in
    select m.* from public.mari_conversas m
     where m.canal = 'whatsapp' and m.chatwoot_conversation_id is not null
       and coalesce(m.chatwoot_status, 'open') = 'open'
       and coalesce(m.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada', 'teste_duplicada')   -- duplicada: várias linhas da mesma conversa
       and coalesce(m.quadro_encerrada_motivo, '') <> 'suporte_nio'
       and m.chatwoot_agente is null and not coalesce(m.humano_atribuido, false) and not coalesce(m.time_atribuido, false)
       and (m.venda_id is null or exists (select 1 from public.vendas v where v.id = m.venda_id and v.status = 'saida'))
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
     limit 30
     for update of m skip locked
  loop
    select t.papel, t.created_at into ult from public.mari_turnos t
     where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano') order by t.created_at desc limit 1;
    if ult.papel is null or ult.created_at > p_agora - interval '5 minutes' then continue; end if;
    if ult.papel = 'lead' then
      select max(t.created_at) into nosso from public.mari_turnos t where t.conversa_id = c.id and t.papel in ('mari', 'humano');
      if nosso is null then continue; end if;
      if exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' and t.created_at > nosso
                    and (t.midia is not null or not public._saida_so_confirmacao(t.texto))) then continue; end if;
    end if;
    perform public._bo_enfileirar(gen_random_uuid(), 1, 'saida_fechar', c.venda_id, c, 'resolver', jsonb_build_object('status', 'resolved'));
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[Saída aberta sem ninguém com o que fazer (' || case when ult.papel = 'lead' then 'o cliente só confirmou ou se despediu'
            else 'a última fala é nossa' end || ') — resolvida no Chatwoot (0249); se ele escrever, reabre]', false);
    n := n + 1;
  end loop;
  return n;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_saidas_fechar', sqlerrm);
  return n;
end $$;
revoke all on function public._saidas_fechar(timestamptz) from public, anon, authenticated;

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
  perform public._saidas_fechar(p_agora);       -- 0249: Saída aberta sem ninguém com o que fazer
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

commit;
