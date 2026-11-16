-- NIOGEN | supabase/migrations/0227_dono_da_conversa.sql | 15/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (15/11 ~20h, "Sim, siga para o bloco do dono da conversa"): bloco "Dono da conversa" da revisão dos fluxos
-- (docs/REVISAO_ciclo_fluxos_151126_1920.md). Regra única: toda conversa tem um dono real, e ele sai quando o ciclo fecha.
--   D3  mari_chatwoot_sync + gatilho novo em chatwoot_acoes: "pessoa/time atribuído" no banco espelha o Chatwoot (antes só ligava,
--       nunca desligava → cadência travada para sempre; caso Ivon). Backfill: desmarca onde o Chatwoot já mostra sem dono.
--   D2  _conversas_volta_mari: já é cliente Nio fica com o time enquanto há conversa; 72 h sem ninguém falar → o ciclo fecha
--       (resolvida ou adiada). Os 8 presos saem pela própria rotina. Se voltar a escrever, a Mari vê a Saída e passa ao time.
--   D5  lead_reabrir recusa reabrir quando a regra dura continua (fora da área, sem cobertura, já cliente Nio) e diz o que
--       corrigir; a cadência não toca esses destinos.
--   D6  lead_reabrir fecha o ciclo de qualquer handoff sem pessoa e sem time (antes só recusa/sem contato).
--   D7  lead_sair "não contatar" numa venda cala a conversa e tira o dono.
--   D8/D12 gatilho novo em vendas: venda que vai para Saída por outro caminho (cancelamento da Nio no OSAB, operador) devolve a
--       conversa para a Mari na hora, como a Saída manual (0224). Backfill: vendas em Saída com conversa aberta e com dono (Mirian).
--   D9  _nao_contatar_etiqueta: a etiqueta sai também em conversa de recusa (a exceção era da época antes da 0189).
--   D10 mari_cadencia_avaliar: ⏸ Aguardar pausa a cadência até a data.
--   D11 oportunidade_enviar: 🔥 sem assumir com time atribuído — sem venda viva o time sai (a Mari segue de verdade); com venda
--       viva a nota diz que segue com o time. lead_reabrir aceita reabrir a conversa de uma venda viva (o 🔥 falhava calado).
--   D4  (handoff "interesse caindo"/"múltiplos decisores" sem time) não muda: a caixa 5 da Live já pega e sobe para Para fazer.
-- Cada função foi recriada a partir da versão no ar (conferida igual ao arquivo antes da mudança).
-- Regra 20: nenhum estado novo; todo dono que sai tem autor no turno de sistema e nota no Chatwoot; nada no mari_principal.
begin;

create or replace function public.lead_sair(p_conversa uuid, p_venda uuid, p_motivo text, p_sub text default null,
                                            p_volta date default null, p_obs text default null, p_cancelou_portal boolean default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  k       public.config_lead;
  c       public.mari_conversas;
  v       public.vendas;
  perfil  text := coalesce(public.meu_perfil(), '');
  sub     text := nullif(btrim(coalesce(p_sub, '')), '');
  antigo  text;
  aberto  boolean := false;
  feito   text[] := '{}';
  g2      uuid;
begin
  if perfil not in ('admin', 'backoffice', 'vendedor') then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into k from public.config_lead where parceiro_id = 'dharma' and tipo = 'saida' and codigo = p_motivo;
  if not found then raise exception 'Motivo de saída desconhecido: %', p_motivo; end if;
  if p_conversa is not null then
    select * into c from public.mari_conversas where id = p_conversa;
    if not found then raise exception 'Conversa não encontrada.'; end if;
  end if;
  if coalesce(p_venda, c.venda_id) is not null then
    select * into v from public.vendas where id = coalesce(p_venda, c.venda_id) for update;
    if not found then raise exception 'Venda não encontrada.'; end if;
    if c.id is null then
      select * into c from public.mari_conversas where venda_id = v.id and canal = 'whatsapp' order by created_at desc limit 1;
    end if;
  end if;
  if v.id is null and c.id is null then raise exception 'Informe a conversa ou a venda.'; end if;
  if perfil = 'vendedor' and (v.id is null or auth.uid() not in (v.vendedor_id, v.criado_por)) then
    raise exception 'Vendedor só registra a saída da própria venda.' using errcode = '42501';
  end if;
  if p_motivo = 'recusou' and sub is null then raise exception 'Diga o porquê da recusa: preço, concorrente, momento, desistiu ou outro.'; end if;
  if p_volta is not null and p_volta <= (now() at time zone 'America/Sao_Paulo')::date then raise exception 'A data de volta precisa ser futura.'; end if;
  perform set_config('niogen.saida_manual', '1', true);   -- 0227: o gatilho da venda (_venda_saida_devolve) não repete o que a Saída faz aqui

  if v.id is not null then
    if v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') then
      raise exception 'Venda instalada não vai para Saída. Cancelamento depois de instalar vem do OSAB.';
    end if;
    aberto := nullif(btrim(v.nio_pedido), '') is not null or nullif(btrim(v.nio_os), '') is not null;
    if aberto and p_cancelou_portal is null then
      raise exception 'Esta venda tem pedido aberto na Nio. Diga se o pedido já foi cancelado no portal.';
    end if;
    update public.vendas
       set status = 'saida',
           motivo_saida = k.nome || coalesce(' · ' || sub, '') || coalesce(' — ' || nullif(btrim(p_obs), ''), ''),
           interesse_futuro_em = p_volta, saida_motivo = k.codigo, saida_sub = sub
     where id = v.id;
    feito := feito || ('Saída · ' || k.nome)::text;
    -- 0227 (D7): "não contatar" numa venda também cala a conversa (antes só sem venda)
    if p_motivo = 'nao_contatar' and c.id is not null then
      update public.mari_conversas set nao_contatar = true, processando_ate = null where id = c.id and not coalesce(nao_contatar, false);
      if found then
        insert into public.mari_turnos (conversa_id, papel, texto, pendente) values (c.id, 'sistema', '[não contatar — saída registrada no NIOGEN]', false);
      end if;
    end if;
    if aberto and p_cancelou_portal then
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'cancelado_no_portal', jsonb_build_object('quando', 'na saída'), auth.uid());
      feito := feito || 'pedido cancelado no portal (confirmado)'::text;
    elsif aberto then
      feito := feito || 'falta cancelar o pedido na Nio — a linha fica na Live até confirmar'::text;
    end if;
  else
    -- conversa sem venda: passa pelo caminho de sempre (nota, etiqueta e resolve no Chatwoot)
    if p_motivo in ('reprovado_biometria', 'nio_nao_instalou', 'venda_indevida_fraude') then
      raise exception 'Esse motivo só vale para lead com venda.';
    end if;
    antigo := case p_motivo when 'cidade_nao_atendida' then 'fora_area' when 'fachada_nao_atendida' then 'sem_cobertura'
                            when 'nao_contatar' then 'recusou' else p_motivo end;
    if p_motivo = 'nao_contatar' then perform public.conversa_nao_contatar(c.id, 'saída registrada no NIOGEN'); end if;
    perform public.backoffice_conversa_saida(c.id, antigo);
    feito := feito || ('Saída · ' || k.nome)::text;
  end if;

  if c.id is not null then
    update public.mari_conversas
       set saida_motivo = k.codigo, saida_sub = sub, saida_volta_em = p_volta, saida_em = now()
     where id = c.id;
  end if;
  -- 0224 (Ricardo, caso Lucas Heleno: "Dei saída… Não deveria ter voltado para a Mari?"): a Saída devolve a conversa para a Mari
  -- na hora (antes só depois de 24 h, pela 0200). Se o cliente voltar a escrever, é ela quem responde. "Não contatar" fica calado
  -- e "já é cliente Nio" fica com o time (0225).
  -- Crédito negado fica gravado também na conversa, para a Mari não consultar de novo o mesmo CPF.
  if c.id is not null and p_motivo = 'credito_negado' then
    update public.mari_conversas set credito_resultado = 'negado', credito_em = coalesce(credito_em, now()) where id = c.id;
  end if;
  -- 0225: "já é cliente Nio" fica com o time (suporte; regra da 0200) — a Mari não atende cliente Nio.
  -- 0227 (D7): "não contatar" também tira o dono (ninguém fala; a Mari está calada pelo não contatar)
  if c.id is not null and p_motivo <> 'ja_cliente_nio'
     and (coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null or c.status = 'handoff_realizado') then
    update public.mari_conversas set humano_atribuido = false, time_atribuido = false where id = c.id;
    if c.status = 'handoff_realizado' then
      perform public._mari_fechar_ciclo(c.id, 'saída registrada no NIOGEN — a conversa volta para a Mari');
    end if;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[saída "' || k.nome || '" registrada — ' || case when p_motivo = 'nao_contatar' then 'dono retirado; ninguém fala com o cliente]' else 'a conversa voltou para a Mari]' end, false);
    if coalesce(c.chatwoot_conversation_id, '') <> '' and c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%' then
      g2 := gen_random_uuid();
      perform public._bo_enfileirar(g2, 1, 'saida_devolver', v.id, c, 'etiquetas',
        jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
      perform public._bo_enfileirar(g2, 2, 'saida_devolver', v.id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      perform public._bo_enfileirar(g2, 3, 'saida_devolver', v.id, c, 'desatribuir', jsonb_build_object('team_id', null));
      perform public._bo_enfileirar(g2, 4, 'saida_devolver', v.id, c, 'nota',
        jsonb_build_object('content', case when p_motivo = 'nao_contatar'
          then '🚫 Saída "' || k.nome || '" registrada — dono retirado. Ninguém fala com este cliente.'
          else '↩ Saída "' || k.nome || '" registrada — a conversa voltou para a Mari. Se o cliente escrever, ela responde.' end));
    end if;
    feito := feito || case when p_motivo = 'nao_contatar' then 'dono retirado (não contatar)' else 'conversa devolvida para a Mari' end;
  end if;
  if p_volta is not null then feito := feito || ('volta para a Live em ' || to_char(p_volta, 'DD/MM'))::text; end if;
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'pedido_aberto', aberto and not coalesce(p_cancelou_portal, false),
                            'resumo', '✓ ' || array_to_string(feito, ' · '));
end;
$$;

create or replace function public.lead_reabrir(p_conversa uuid, p_venda uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c public.mari_conversas;
  v public.vendas;
  novo text;
  v_opt timestamptz;
  v_tirar jsonb;
  v_nc boolean := false;
  v_dest text;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then raise exception 'Só admin ou backoffice.' using errcode = '42501'; end if;
  if p_conversa is not null then select * into c from public.mari_conversas where id = p_conversa; end if;
  if coalesce(p_venda, c.venda_id) is not null then
    select * into v from public.vendas where id = coalesce(p_venda, c.venda_id) for update;
    if c.id is null then select * into c from public.mari_conversas where venda_id = v.id and canal = 'whatsapp' order by created_at desc limit 1; end if;
  end if;
  if v.id is null and c.id is null then raise exception 'Informe a conversa ou a venda.'; end if;
  -- 0189: quem pediu para parar com as próprias palavras só reabre se voltar a escrever
  if c.id is not null and coalesce(c.nao_contatar, false) then
    v_nc := true;
    select max(t.created_at) into v_opt from public.mari_turnos t
     where t.conversa_id = c.id and t.papel = 'sistema' and t.texto like '[não contatar — cliente escreveu:%';
    if v_opt is not null and not exists (select 1 from public.mari_turnos t
                                          where t.conversa_id = c.id and t.papel = 'lead' and t.created_at > v_opt) then
      raise exception 'O cliente pediu para parar de receber mensagens. Só dá para reabrir se ele escrever de novo.';
    end if;
  end if;
  if v.id is not null then
    if v.status <> 'saida' then
      -- 0227 (D11): venda viva com a conversa num destino de saída (ex.: 🔥 numa conversa encerrada) → reabre só a conversa
      if c.id is null or coalesce(c.funil_destino, 'em_andamento') in ('em_andamento', 'instalada', 'teste_duplicada') then
        raise exception 'A venda não está em Saída.';
      end if;
    else
      novo := case when nullif(btrim(v.nio_os), '') is null then '0_qualificado'
                   when v.instalacao_agendada_para is not null then '2_aguardando_instalacao' else '1_vendido' end;
      update public.vendas set status = novo, interesse_futuro_em = null where id = v.id;   -- as travas da venda (vendas_antes_status) valem
    end if;
  end if;
  if c.id is not null then
    -- 0189: saída automática por recusa ou sem contato, sem dono → o ciclo fecha e a Mari volta a responder
    -- 0227 (D6): qualquer handoff sem pessoa e sem time fecha o ciclo (antes só recusa/sem contato → handoff sem dono)
    if c.status = 'handoff_realizado' and not coalesce(c.humano_atribuido, false) and c.chatwoot_agente is null
       and (c.handoff_motivo in ('recusa_compra', 'sem_contato') or (not coalesce(c.time_atribuido, false) and c.chatwoot_time is null)) then
      perform public._mari_fechar_ciclo(c.id, 'reaberto no NIOGEN');
    end if;
    update public.mari_conversas
       set quadro_encerrada_motivo = null, quadro_encerrada_em = null, quadro_encerrada_por = null, funil_evento = 'reabrir',
           nao_contatar = false, chatwoot_resolvida = false
     where id = c.id;
    -- 0227 (D5): a regra dura continua valendo (CEP fora da área, sem cobertura, já é cliente Nio) → não reabre: diz o que corrigir
    select funil_destino into v_dest from public.mari_conversas where id = c.id;
    if v_dest in ('fora_area', 'sem_cobertura', 'ja_cliente_nio') then
      raise exception '%', case v_dest
        when 'fora_area' then 'Não reabre: o CEP deste lead continua fora da área. Corrija o CEP/endereço na ficha e depois reabra.'
        when 'sem_cobertura' then 'Não reabre: a viabilidade deste endereço continua sem cobertura. Refaça a viabilidade (ou corrija o endereço) e depois reabra.'
        else 'Não reabre: este cliente consta como já cliente Nio. Se não for, corrija na ficha e depois reabra.' end;
    end if;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[reaberto no NIOGEN por ' || coalesce((select u.nome from public.usuarios u where u.id = auth.uid()), 'alguém do time')
            || case when v_nc then ' — "não contatar" retirado' else '' end || ']', false);
    if coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%' and c.canal = 'whatsapp' then
      perform public._bo_enfileirar(gen_random_uuid(), 1, 'reabrir', c.venda_id, c, 'resolver', jsonb_build_object('status', 'open'));
      select jsonb_agg(e) into v_tirar from unnest(coalesce(c.chatwoot_etiquetas, '{}'::text[])) e where e = 'nao-contatar';   -- as saida-* já saem pelo gatilho do destino
      if v_tirar is not null then
        perform public._bo_enfileirar(gen_random_uuid(), 2, 'reabrir', c.venda_id, c, 'etiquetas', jsonb_build_object('add', '[]'::jsonb, 'remove', v_tirar));
      end if;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'resumo', '✓ reaberto' || coalesce(' — venda de volta em ' || novo, '')
                            || case when v_nc then ' · "não contatar" retirado' else '' end);
end;
$$;

CREATE OR REPLACE FUNCTION public.mari_cadencia_avaliar(p_agora timestamp with time zone DEFAULT now(), p_conversa uuid DEFAULT NULL::uuid)
 RETURNS TABLE(conversa_id uuid, telefone text, canal text, chatwoot_conversation_id text, status text, etapa text, passo_atual text, passo_em timestamp with time zone, proximo_passo text, proximo_em timestamp with time zone, pode_enviar boolean, bloqueio text, acao text, template text, categoria text, params jsonb, texto text, excecao text, janela_aberta boolean, janela_fecha_em timestamp with time zone, toques_hoje integer, toques_mes integer, ligar_sugerido boolean, venda_id uuid)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  c        public.mari_conversas;
  v_tq     record;
  v_teto   record;   -- 0102: config_regras.contato_teto_dia/_mes (nulo = sem teto)
  L        timestamptz;   -- última msg do lead
  M        timestamptz;   -- última msg da Mari
  B        timestamptz;   -- base dos D (lead, retorno ou 1º contato)
  f1_at    timestamptz; f_base timestamptz; f_ant timestamptz; fats timestamptz[]; fval timestamptz[]; k int; k2 int; f2_at timestamptz; f2_ate timestamptz; a_ant timestamptz;
  d3_at    timestamptz; d7_at timestamptz; d15_at timestamptz; enc_at timestamptz;
  seq      text[]; ats timestamptz[]; validos timestamptz[];
  idx_atual int; i int; alvo int; prox int;
  v_passo  text; v_at timestamptz; v_bloq text; v_acao text; v_tpl text; v_cat text; v_params jsonb; v_txt text;
  v_exc    text; v_pode boolean; v_janela boolean; v_lig boolean;
  v_venda  record; vis_dia date; vis_ini timestamptz; v_proib text;
  v_turno  text; v_dia date;
  v_dom    boolean;   -- 0209: véspera no domingo/feriado (exceção do Ricardo, 15/11)
  v_inst   boolean;
  v_volta  timestamptz;   -- 0196   -- 0114: venda com instalação agendada (aviso/lembrete são da venda, não da conversa)
  l15_at   timestamptz; v_ab_em timestamptz; v_ab_tags jsonb;   -- 0070: lembrete leve da abertura B2
  semana   text[] := array['segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado','domingo'];
begin
  select * into v_teto from public.contato_teto();
  for c in
    select * from public.mari_conversas mc
     where (p_conversa is null or mc.id = p_conversa)
       and mc.canal in ('teste', 'whatsapp')
       and (mc.status = 'ativo'
            or (mc.status = 'handoff_realizado' and mc.venda_id is not null))   -- biometria pendente / instalação agendada
     order by mc.updated_at desc
  loop
    v_passo := null; v_at := null; v_bloq := null; v_acao := null; v_tpl := null; v_cat := null;
    v_params := null; v_txt := null; v_exc := null; v_pode := false; v_lig := false;
    L := c.ultima_msg_lead_at; M := c.ultima_msg_mari_at;
    v_janela := L is not null and p_agora < L + interval '23 hours';
    select * into v_tq from public.mari_toques(c.telefone, p_agora);
    -- ── paradas absolutas ──
    if c.nao_contatar then v_bloq := 'cliente pediu para não ser contatado';
    elsif c.humano_atribuido then v_bloq := 'humano atribuído no Chatwoot';
    elsif c.time_atribuido then v_bloq := 'time atribuído no Chatwoot';
    elsif c.chatwoot_resolvida then v_bloq := 'conversa resolvida no Chatwoot';
    -- 0227 (D10): ⏸ Aguardar pausa a cadência até a data (se o cliente escrever, a Mari responde normalmente)
    elsif c.espera_ate is not null and c.espera_ate > p_agora then
      v_bloq := 'em espera (⏸) até ' || to_char(c.espera_ate at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
    -- 0227 (D5): destino de saída pela regra (CEP fora da área, sem cobertura, já é cliente Nio) não recebe toque
    elsif c.funil_destino in ('fora_area', 'sem_cobertura', 'ja_cliente_nio') then
      v_bloq := 'destino de saída pela regra (' || c.funil_destino || ')';
    elsif c.canal = 'whatsapp' and c.telefone like '5500000000%' then v_bloq := 'telefone de teste';
    -- 0064 (08/11): venda "Em espera" (pendência com terceiro aberta) pausa toda a cadência até a pendência ser encerrada.
    elsif c.venda_id is not null and exists (select 1 from public.venda_pendencias vp
                                              where vp.venda_id = c.venda_id and vp.encerrada_em is null) then
      v_bloq := 'venda em espera (pendência com terceiro)';
    end if;
    -- 0114 (Ricardo, 10/11 ~20h40 "Sim, faça os dois"): o aviso do agendamento (C2) e o lembrete da véspera (C3) são da VENDA —
    -- saem com a conversa em qualquer estado (ativa ou em handoff), com humano/time atribuído, resolvida no Chatwoot ou com
    -- pendência aberta. Só "não contatar" e telefone de teste param.
    v_inst := c.venda_id is not null and exists (select 1 from public.vendas vi where vi.id = c.venda_id
                and vi.status = '2_aguardando_instalacao' and vi.instalacao_agendada_para > p_agora);
    if v_inst and not coalesce(c.nao_contatar, false) and not (c.canal = 'whatsapp' and c.telefone like '5500000000%') then
      v_bloq := null;
    end if;
    if c.status = 'handoff_realizado' or v_inst then
      -- ── venda remota (05/11): biometria pendente e instalação agendada ──
      if v_bloq is not null then continue; end if;
      select v.id, v.status, v.biometria_status, v.biometria_link, v.biometria_link_enviado_em, v.forma_pagamento, v.biometria_validada_em,
             exists (select 1 from public.os_andamento oa where oa.venda_id = v.id and oa.estado is not null
                       and oa.estado <> 'aguardando_pagamento' and oa.mudou_em > v.biometria_validada_em) as cartao_ok,
             v.instalacao_agendada_para, v.instalacao_turno, v.logradouro, v.numero, v.complemento, v.bairro
        into v_venda
        from public.vendas v
       where v.id = c.venda_id and v.status <> 'saida';
      if not found then continue; end if;
      -- 0191: a biometria vem DEPOIS da OS — os lembretes valem também com a venda já contada (Ativação/Agenda).
      if v_venda.status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao') and v_venda.biometria_status = 'pendente' and v_venda.biometria_link_enviado_em is not null then
        select q.fim into v_volta from public.biometria_quedas q
         where q.fim is not null and q.fim > p_agora - interval '48 hours' and q.inicio > v_venda.biometria_link_enviado_em - interval '15 days'
           and v_venda.biometria_link_enviado_em < q.fim
         order by q.fim desc limit 1;
        if v_volta is not null and (c.bio_volta_em is null or c.bio_volta_em < v_volta) then
          -- 0196: a biometria da Nio voltou depois de uma queda e este cliente ficou esperando: a Mari avisa (só na janela de 24 h).
          v_passo := 'BIOVOLTA'; v_at := v_volta;
          select replace(t.texto, '{nome}', public.mari_cadencia_nome(c)) into v_txt from public.config_mari_textos t where t.chave = 'mari_bio_voltou';
          v_acao := 'texto'; v_tpl := null;
          if not v_janela then v_bloq := 'janela de 24 h fechada: o time fala com o cliente (Live)'; end if;
        elsif c.bio_lembrete_em is null or c.bio_lembrete_em < v_venda.biometria_link_enviado_em then
          -- BIO1: D+1 do link, uma vez só. 0032: o link é da Nio (WhatsApp + e-mail, na hora do pedido) — a contagem parte
          -- da hora do pedido e o lembrete é o C1 v2 (sem botão de link): lembra que a Nio mandou, conferir o spam, ajuda por aqui.
          v_passo := 'BIO1';
          v_at := public.mari_proximo_horario(v_venda.biometria_link_enviado_em + interval '1 day', c.cidade);
          v_tpl := 'nio_lembrete_biometria_v2';
          v_params := jsonb_build_array(public.mari_cadencia_nome(c));
          v_txt := public.mari_render_template(v_tpl, v_params);
          if v_janela then
            v_acao := 'texto'; v_tpl := null;   -- texto livre (janela de 24 h): o mesmo texto do C1 v2
          else
            v_acao := 'template'; v_cat := 'UTILITY';
          end if;
          if p_agora < v_at then v_bloq := 'aguardando o D+1 do link da biometria (hora do pedido)';
          end if;
        else
          -- BIO3: D+3 sem biometria → o humano liga. Nunca automático.
          v_passo := 'BIO3'; v_acao := 'ligar';
          v_at := v_venda.biometria_link_enviado_em + interval '3 days';
          v_lig := p_agora >= v_at;
          v_bloq := case when p_agora < v_at then 'aguardando o D+3 do link da biometria (hora do pedido)'
                         else 'D+3 sem biometria: o nosso time liga para o cliente (nunca automático)' end;
        end if;
      elsif v_venda.status = '2_aguardando_instalacao' and v_venda.instalacao_agendada_para > p_agora
            and v_venda.biometria_status = 'validada' then   -- 0191: confirmação da instalação só depois da biometria aprovada
        v_dia := (v_venda.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date;
        v_turno := coalesce(v_venda.instalacao_turno,
                            case when extract(hour from v_venda.instalacao_agendada_para at time zone 'America/Sao_Paulo') >= 12
                                 then 'tarde' else 'manha' end);
        if v_venda.forma_pagamento = 'cartao' and not v_venda.cartao_ok and c.cartao_avisado_em is null then
          -- 0191 (Ricardo, 14/11): cartão — biometria aprovada, a Nio manda o link do cadastro do cartão. A Mari avisa com jeitinho.
          v_passo := 'CARTAO'; v_at := p_agora;
          v_params := jsonb_build_array(public.mari_cadencia_nome(c),
            semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM'),
            case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end);
          select replace(replace(replace(t.texto, '{nome}', v_params ->> 0), '{dia}', v_params ->> 1), '{periodo}', v_params ->> 2)
            into v_txt from public.config_mari_textos t where t.chave = 'mari_cartao_aviso';
          if v_janela then v_acao := 'texto'; v_tpl := null;
          else v_acao := 'template'; v_tpl := 'nio_cartao_cadastro'; v_cat := 'UTILITY'; end if;
        elsif v_venda.forma_pagamento = 'cartao' and not v_venda.cartao_ok and c.cartao_lembrete_em is null then
          -- 0191: 24 h sem o cadastro do cartão → um lembrete gentil. 48 h → o time liga (v_jornada / Live).
          v_passo := 'CARTAO2';
          -- 0198 (Ricardo/Rogério, 14/11): a Nio agenda mesmo sem o cartão, mas sem o cadastro NÃO instala — o lembrete sai
          -- em 24 h ou na véspera da visita, o que vier primeiro (nunca antes de 2 h do aviso).
          vis_dia := v_dia - 1;
          while not public.mari_dia_toque(vis_dia, c.cidade) loop vis_dia := vis_dia - 1; end loop;
          v_at := greatest(c.cartao_avisado_em + interval '2 hours',
                    least(public.mari_proximo_horario(c.cartao_avisado_em + interval '24 hours', c.cidade),
                          public.mari_proximo_horario((vis_dia::timestamp) at time zone 'America/Sao_Paulo', c.cidade)));
          v_params := jsonb_build_array(public.mari_cadencia_nome(c),
            semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM'),
            case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end);
          select replace(replace(replace(t.texto, '{nome}', v_params ->> 0), '{dia}', v_params ->> 1), '{periodo}', v_params ->> 2)
            into v_txt from public.config_mari_textos t where t.chave = 'mari_cartao_lembrete';
          if v_janela then v_acao := 'texto'; v_tpl := null;
          else v_acao := 'template'; v_tpl := 'nio_cartao_cadastro'; v_cat := 'UTILITY'; end if;
          if p_agora < v_at then v_bloq := 'aguardando o lembrete do cartão (24 h ou a véspera da visita)'; end if;
        elsif v_venda.forma_pagamento = 'cartao' and not v_venda.cartao_ok then
          continue;   -- 0191: lembrete já saiu; esperando o cadastro do cartão (48 h → o time liga)
        elsif c.instalacao_avisada_para is distinct from v_venda.instalacao_agendada_para then
          -- C2: assim que agendar (ou reagendar).
          v_passo := 'INSTALACAO'; v_at := p_agora;
          v_params := jsonb_build_array(
            public.mari_cadencia_nome(c),
            semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM'),
            case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end,
            concat_ws(', ', nullif(btrim(v_venda.logradouro), ''), nullif(btrim(v_venda.numero), ''),
                      nullif(btrim(v_venda.complemento), ''), nullif(btrim(v_venda.bairro), '')));
          v_tpl := 'nio_instalacao_agendada';
        elsif c.instalacao_lembrada_para is distinct from v_venda.instalacao_agendada_para then
          -- C3: véspera (dia permitido anterior).
          vis_dia := v_dia - 1;
          while not public.mari_dia_toque(vis_dia, c.cidade) loop vis_dia := vis_dia - 1; end loop;
          -- 0209 (Ricardo, 15/11: "nesse caso, pode abrir uma exceção e enviar no domingo"): se o aviso do agendamento (C2) saiu
          -- no dia da véspera permitida ou depois (ex.: instalação na segunda agendada no sábado à tarde), a véspera não teria dia
          -- nenhum — então ela sai no dia anterior à instalação mesmo sendo domingo/feriado, das 10h às 16h.
          v_dom := c.instalacao_avisada_em is not null
                   and vis_dia <= (c.instalacao_avisada_em at time zone 'America/Sao_Paulo')::date
                   and (v_dia - 1) > (c.instalacao_avisada_em at time zone 'America/Sao_Paulo')::date;
          if v_dom then vis_dia := v_dia - 1; end if;
          vis_ini := case when v_dom then (vis_dia::timestamp + time '10:00') at time zone 'America/Sao_Paulo'
                          else public.mari_proximo_horario((vis_dia::timestamp) at time zone 'America/Sao_Paulo', c.cidade) end;
          v_passo := 'VESPERA'; v_at := vis_ini;
          v_params := jsonb_build_array(public.mari_cadencia_nome(c), to_char(v_dia, 'DD/MM'),
                                        case v_turno when 'tarde' then 'tarde' else 'manhã' end);
          v_tpl := 'nio_lembrete_instalacao';
          if p_agora < v_at then v_bloq := 'aguardando a véspera da instalação';
          -- 0114: o texto diz "é amanhã" — nunca sai no próprio dia da instalação.
          elsif (p_agora at time zone 'America/Sao_Paulo')::date >= v_dia then v_bloq := 'a véspera passou (o lembrete diz "amanhã")';
          elsif p_agora > v_venda.instalacao_agendada_para - interval '2 hours' then v_bloq := 'instalação próxima demais';
          elsif c.instalacao_avisada_em > p_agora - interval '12 hours' then v_bloq := 'o aviso do agendamento (C2) saiu há menos de 12 h';
          elsif v_dom and p_agora >= (vis_dia::timestamp + time '16:00') at time zone 'America/Sao_Paulo' then v_bloq := 'a véspera passou (o lembrete diz "amanhã")';
          elsif v_dom then v_exc := 'véspera no domingo/feriado: sem outro dia antes da instalação';   -- passa pela regra do horário (só 10h–16h, acima)
          end if;
        else
          continue;
        end if;
        if v_passo in ('INSTALACAO', 'VESPERA') then
        v_txt := public.mari_render_template(v_tpl, v_params);
        -- 0114: aviso e lembrete da instalação saem SEMPRE como template (com os botões Confirmo/Tudo certo · Preciso remarcar),
        -- mesmo com a janela aberta — a resposta ao botão é o que preenche "Confirmou?" (0112).
        v_acao := 'template'; v_cat := 'UTILITY';
        end if;
      else
        continue;   -- nada a fazer nesta conversa em handoff
      end if;
    elsif v_bloq is null and c.status = 'ativo' then
      -- 0050 (Ricardo, 06/11): venda em Saída não recebe nada da cadência ("Interesse futuro" vira etiqueta no
      -- Chatwoot, 0052; "Sem cobertura" não ganha nada).
      if c.venda_id is not null and exists (select 1 from public.vendas vs where vs.id = c.venda_id and vs.status = 'saida') then
        continue;
      end if;
      -- ── retorno pedido pelo cliente: prioridade, pode sair fora do horário ──
      if c.agendamento_retorno is not null
         and c.agendamento_retorno > coalesce(L, c.created_at)
         and (c.cadencia_retorno_em is null or c.cadencia_retorno_em < c.agendamento_retorno) then
        v_passo := 'RETORNO'; v_at := c.agendamento_retorno; v_exc := 'pedido do cliente';
        if v_janela then
          v_acao := 'texto';
          v_txt := 'Oi' || case when public.mari_cadencia_nome(c) <> 'tudo bem' then ', ' || public.mari_cadencia_nome(c) else '' end
                   || '! Como combinamos, estou passando pra gente retomar. Quer seguir de onde paramos? 😊';
        else
          v_acao := 'template'; v_tpl := 'nio_retomada_lead_d3'; v_cat := 'MARKETING';
          v_params := jsonb_build_array(public.mari_cadencia_nome(c), public.mari_cadencia_contexto(c));
          v_txt := public.mari_render_template(v_tpl, v_params);
        end if;
        if p_agora < v_at then v_bloq := 'retorno agendado pelo cliente'; end if;
      elsif c.processando_ate is not null and c.processando_ate > p_agora then
        v_bloq := 'Mari respondendo agora';
      elsif L is null and c.origem not in ('meta_ads', 'site', 'indicacao') then
        continue;   -- sem mensagem do lead e sem origem de formulário: não há escada
      -- 0199 (trava A): a resposta do TIME também é resposta. Antes, o time respondia, devolvia para a Mari e a escada nunca
      -- recomeçava (M < L para sempre) — Leandro e Lucia Dias parados em silêncio.
      elsif L is not null and (M is null or M < L) and c.cadencia_passo = 'nenhum'
            and not exists (select 1 from public.mari_turnos th where th.conversa_id = c.id and th.papel = 'humano' and th.created_at >= L) then
        v_bloq := 'aguardando a Mari responder';
      else
        -- ── a escada ──
        B := greatest(coalesce(L, '-infinity'::timestamptz), coalesce(c.cadencia_retorno_em, '-infinity'::timestamptz));
        if L is null then
          B := coalesce((select min(cc.em) from public.contatos_cliente cc where cc.conversa_id = c.id and cc.toque = 'P1'),
                        c.cadencia_passo_em, c.created_at);
          seq := array['P1', 'D7', 'D15', 'ENCERRAR'];
          ats := array[c.created_at, B + interval '7 days', B + interval '15 days', null];
          validos := array[B + interval '7 days', B + interval '15 days', 'infinity'::timestamptz, 'infinity'::timestamptz];
        else
          -- 0141 (Ricardo, 12/11): 5 cutucadas na janela de 24 h, em QUALQUER etapa: 15 min, 1 h, 3 h e 6 h depois da última fala
          -- REAL da Mari e a última chamada ~20 h depois da mensagem do cliente. Fora do horário do contrato (seg–sex 9–21, sáb
          -- 10–16, nunca domingo/feriado) vai para a abertura seguinte, com no mínimo 45 min entre duas, se ainda couber na janela
          -- (até L + 23 h); senão é pulada. O cliente respondeu → L muda e a escada recomeça. Substitui L15/F1/F2.
          -- 0199: a última fala real é da Mari OU do time (a cutucada não sai 15 min depois de uma fala velha da Mari
          -- quando o time acabou de responder).
          f_base := coalesce((select max(t.created_at) from public.mari_turnos t
                               where t.conversa_id = c.id and t.papel in ('mari', 'humano') and coalesce(t.tags ->> 'cadencia', '') = ''), M);
          fats := array[f_base + interval '15 minutes', f_base + interval '1 hour', f_base + interval '3 hours',
                        f_base + interval '6 hours', L + interval '20 hours'];
          f_ant := null;
          for k in 1..5 loop
            if c.cadencia_retorno_em is not null then fats[k] := null; continue; end if;
            if f_ant is not null and fats[k] < f_ant + interval '45 minutes' then fats[k] := f_ant + interval '45 minutes'; end if;
            if not public.mari_no_horario(fats[k], c.cidade) then fats[k] := public.mari_proximo_horario(fats[k], c.cidade); end if;
            if fats[k] is null or fats[k] >= L + interval '23 hours' then fats[k] := null; else f_ant := fats[k]; end if;
          end loop;
          fval := array[null, null, null, null, null]::timestamptz[];
          for k in 1..5 loop
            fval[k] := L + interval '23 hours';
            if k < 5 then
              for k2 in (k + 1)..5 loop
                if fats[k2] is not null then fval[k] := least(fats[k2], fval[k]); exit; end if;
              end loop;
            end if;
          end loop;
          d3_at := B + interval '3 days'; d7_at := B + interval '7 days'; d15_at := B + interval '15 days';
          seq := array['F1', 'F2', 'F3', 'F4', 'F5', 'D3', 'D7', 'D15', 'ENCERRAR'];
          ats := array[fats[1], fats[2], fats[3], fats[4], fats[5], d3_at, d7_at, d15_at, null];
          validos := array[fval[1], fval[2], fval[3], fval[4], fval[5], d7_at, d15_at,
                           'infinity'::timestamptz, 'infinity'::timestamptz];
        end if;
        if c.cadencia_passo = 'D15' then
          ats[array_length(seq, 1)] := c.cadencia_passo_em + interval '48 hours';
        end if;
        idx_atual := coalesce(array_position(seq, c.cadencia_passo), 0);
        if c.cadencia_passo = 'F2' and seq[1] = 'P1' then idx_atual := 1; end if;
        alvo := null; prox := null;
        for i in (idx_atual + 1)..array_length(seq, 1) loop
          if ats[i] is null then continue; end if;
          if seq[i] in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') and ats[i] <= p_agora and not public.mari_no_horario(p_agora, c.cidade) then continue; end if;
          if ats[i] <= p_agora and p_agora < validos[i] then alvo := i;
          elsif ats[i] > p_agora and prox is null then prox := i;
          end if;
        end loop;
        if alvo is not null then
          v_passo := seq[alvo]; v_at := ats[alvo];
        elsif prox is not null then
          v_passo := seq[prox]; v_at := ats[prox]; v_bloq := 'aguardando';
        else
          continue;
        end if;
        if v_passo in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') then
          v_acao := 'texto'; v_txt := public.mari_cadencia_texto(c, v_passo);
        elsif v_passo = 'ENCERRAR' then
          v_acao := 'encerrar'; v_txt := null;
        else
          v_acao := 'template';
          v_tpl := case v_passo when 'P1' then 'nio_primeiro_contato' when 'D3' then 'nio_retomada_lead_d3'
                                when 'D7' then 'nio_retomada_lead_d7' else 'nio_retomada_lead_d15' end;
          v_cat := 'MARKETING';
          v_params := case when v_tpl = 'nio_retomada_lead_d3'
                           then jsonb_build_array(public.mari_cadencia_nome(c), public.mari_cadencia_contexto(c))
                           else jsonb_build_array(public.mari_cadencia_nome(c)) end;
          v_txt := public.mari_render_template(v_tpl, v_params);
        end if;
        if v_passo in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') and not v_janela then v_bloq := 'janela de 24 h fechada'; end if;
        -- 0050 (Ricardo, 06/11): venda já criada NUNCA sai sozinha e não recebe a escada de templates de lead —
        -- só as cutucadas F1/F2 dentro da janela; o resto é do backoffice, pela venda.
        if c.venda_id is not null and v_passo not in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') then
          v_bloq := 'venda criada: o backoffice segue pela venda (a cadência não manda D3/D7/D15 nem encerra)';
        end if;
        v_lig := c.cadencia_passo = 'D3' and p_agora >= c.cadencia_passo_em + interval '1 day' and p_agora < B + interval '6 days';
      end if;
    end if;
    if v_passo is null then
      if v_bloq is null then continue; end if;
    end if;
    -- 0110 (Ricardo, 10/11 16h02): o time mandou (ou ligou) pela 🔥 oportunidade HOJE e o cliente ainda não respondeu →
    -- nenhum toque automático no mesmo dia (nunca dois toques num dia: um do humano e um da Mari); o próximo vai para o dia
    -- útil seguinte. Retorno pedido pelo cliente (v_exc) segue valendo. Cliente respondeu → L passa da mensagem e a regra é a de sempre.
    if v_bloq is null and v_passo is not null and v_exc is null and v_acao in ('texto', 'template')
       and v_passo not in ('INSTALACAO', 'VESPERA', 'CARTAO', 'CARTAO2', 'BIOVOLTA')   -- 0114: aviso/lembrete da instalação não são toque de venda
       and (exists (select 1 from public.oportunidades_log ol
                    where ol.conversa_id = c.id and ol.tipo = 'enviada'
                      and ol.criado_em > coalesce(L, '-infinity'::timestamptz)
                      and (ol.criado_em at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date)
            -- 0226 (M7): vale para QUALQUER fala do time hoje (NIOGEN ou Chatwoot), não só o 🔥
            or exists (select 1 from public.mari_turnos th
                        where th.conversa_id = c.id and th.papel = 'humano'
                          and th.created_at > coalesce(L, '-infinity'::timestamptz)
                          and (th.created_at at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date)) then
      v_bloq := 'o time falou com o cliente hoje (🔥 oportunidade): o toque vai para o próximo dia útil';
      v_at := greatest(v_at, public.mari_proximo_horario(((p_agora at time zone 'America/Sao_Paulo')::date + 1)::timestamp at time zone 'America/Sao_Paulo', c.cidade));
    end if;
    -- ── regras duras do envio: horário, teto, filtro de texto ──
    if v_bloq is null and v_acao not in ('encerrar', 'ligar') then
      -- 0226 (M5): o retorno pedido pelo cliente também respeita a madrugada (só o horário, não as outras regras)
      if (v_exc is null or v_passo = 'RETORNO') and not public.mari_no_horario(p_agora, c.cidade) then
        v_bloq := 'fora do horário';
        v_at := greatest(v_at, public.mari_proximo_horario(p_agora, c.cidade));
      elsif v_teto.dia is not null and v_tq.hoje >= v_teto.dia then
        v_bloq := 'limite do dia (' || v_teto.dia || ' toques)';
        v_at := greatest(v_at, public.mari_proximo_horario(((p_agora at time zone 'America/Sao_Paulo')::date + 1)::timestamp at time zone 'America/Sao_Paulo', c.cidade));
      elsif v_teto.mes is not null and v_tq.mes >= v_teto.mes then
        v_bloq := 'limite do mês (' || v_teto.mes || ' toques)';
      elsif v_acao = 'template' and not exists (select 1 from public.config_templates_waba t where t.nome = v_tpl and t.status = 'APPROVED') then
        v_bloq := 'template não aprovado';
      else
        v_proib := public.mari_texto_proibido(v_txt);
        if v_proib is not null then v_bloq := 'texto reprovado no filtro (' || v_proib || ')'; end if;
      end if;
    end if;
    v_pode := v_passo is not null and v_bloq is null and v_acao is distinct from 'ligar';
    conversa_id := c.id; telefone := c.telefone; canal := c.canal; chatwoot_conversation_id := c.chatwoot_conversation_id;
    status := c.status; etapa := c.etapa; passo_atual := c.cadencia_passo; passo_em := c.cadencia_passo_em;
    proximo_passo := v_passo; proximo_em := v_at; pode_enviar := v_pode; bloqueio := v_bloq; acao := v_acao;
    template := v_tpl; categoria := v_cat; params := v_params; texto := v_txt; excecao := v_exc;
    janela_aberta := v_janela; janela_fecha_em := case when L is not null then L + interval '24 hours' end;
    toques_hoje := v_tq.hoje; toques_mes := v_tq.mes; ligar_sugerido := v_lig; venda_id := c.venda_id;
    return next;
  end loop;
end;
$function$;

create or replace function public.oportunidade_enviar(p_conversa uuid, p_texto text, p_assumir boolean default false, p_template text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o        record;
  c        public.mari_conversas;
  g        uuid := gen_random_uuid();
  quem     text;
  txt      text := btrim(coalesce(p_texto, ''));
  ult_lead timestamptz;
  v_tpl    public.config_templates_waba;
  v_pay    jsonb;
  v_nome   text;
  aid      bigint;
  r        jsonb;
  agora_t  text := to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI');
  ag       int;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice manda mensagem pelo NIOGEN.' using errcode = '42501';
  end if;
  select * into o from public.v_oportunidades where conversa_id = p_conversa;
  if not found then
    raise exception 'Esta oportunidade não está mais aberta (o cliente respondeu, alguém já mandou ou a janela fechou). Atualize a tela.';
  end if;
  if o.canal = 'ligar' then
    raise exception 'A janela de 24 h fechou e o template da oportunidade ainda não foi aprovado: ligue para o cliente.';
  end if;
  select nome, chatwoot_agente_id into quem, ag from public.usuarios where id = auth.uid();
  quem := coalesce(nullif(split_part(btrim(quem), ' ', 1), ''), 'time');

  select * into c from public.mari_conversas where id = p_conversa for update;
  if c.canal <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' then raise exception 'Esta conversa não está no Chatwoot.'; end if;
  if c.telefone like '5500000000%' then raise exception 'Telefone de teste: nada vai ao Chatwoot.'; end if;
  if coalesce(c.nao_contatar, false) then raise exception 'O cliente pediu para não ser contatado.'; end if;
  if p_template is null and txt = '' then raise exception 'Escreva a mensagem.'; end if;
  if length(txt) > 4000 then raise exception 'Mensagem longa demais (máx. 4.000 caracteres).'; end if;
  select max(t.created_at) into ult_lead from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead';

  if p_template is not null then
    -- 0110: só o template da oportunidade (nunca os da cadência 24h/D3/D7/D15).
    select * into v_tpl from public.config_templates_waba where nome = p_template and status = 'APPROVED' and uso = 'oportunidade';
    if v_tpl.nome is null then raise exception 'Template não aprovado para oportunidade: %', p_template; end if;
    v_nome := public.mari_cadencia_nome(c);
    v_pay := jsonb_build_object('content', public.mari_render_template(v_tpl.nome, jsonb_build_array(v_nome, quem)), 'content_type', 'text',
      'message_type', 'outgoing', 'private', false, 'template', v_tpl.nome,
      'template_params', jsonb_build_object('name', v_tpl.nome, 'category', v_tpl.categoria, 'language', v_tpl.idioma,
        'processed_params', jsonb_build_object('body', jsonb_build_object('1', v_nome, '2', quem))));
  else
    if ult_lead is null or now() >= ult_lead + interval '23 hours' then
      raise exception 'A janela de 24 h fechou: só o template da oportunidade (ou ligar).' using errcode = 'P0001';
    end if;
    v_pay := jsonb_build_object('content', txt, 'message_type', 'outgoing', 'private', false);
  end if;
  v_pay := v_pay || jsonb_build_object('como', 'humano', 'conta', 'sim', 'rotulo', 'oportunidade 🔥', 'oportunidade', o.codigo);

  if coalesce(p_assumir, false) then
    -- Mandar e assumir: atribui a quem mandou (a Mari cala, a cadência para) e manda.
    perform public.mari_cadencia_parar(c.id, p_humano => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[🔥 assumida no NIOGEN por ' || quem || ' ao mandar a oportunidade — cadência parada]', false);
    perform public._bo_enfileirar(g, 1, 'oportunidade', c.venda_id, c, 'atribuir',
      case when ag is not null then jsonb_build_object('assignee_id', ag)
           else jsonb_build_object('team_id', (public._bo_cfg('chatwoot_time_backoffice', '15102') #>> '{}')::int) end);
    aid := public._bo_enfileirar(g, 2, 'oportunidade', c.venda_id, c, 'mensagem', v_pay);
    perform public._bo_enfileirar(g, 3, 'oportunidade', c.venda_id, c, 'nota',
      jsonb_build_object('content', '🔥 Assumida por ' || quem || ' às ' || agora_t || ' (' || coalesce(o.motivo, o.codigo) || ').'));
    r := jsonb_build_object('ok', true, 'acao_id', aid, 'assumiu', true, 'resumo', '✓ mensagem enviada · conversa assumida (a Mari calou)');
  else
    aid := public._bo_enfileirar(g, 1, 'oportunidade', c.venda_id, c, 'mensagem', v_pay);
    perform public._bo_enfileirar(g, 3, 'oportunidade', c.venda_id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
    -- 0227 (D11): com venda viva a conversa segue com o time (aviso real); sem venda viva o time sai também — senão o guard da
    -- Mari vê o time atribuído e ela fica calada, e "a Mari segue" era falso.
    if c.venda_id is not null and exists (select 1 from public.vendas vv where vv.id = c.venda_id and vv.status <> 'saida') then
      perform public._bo_enfileirar(g, 2, 'oportunidade', c.venda_id, c, 'nota',
        jsonb_build_object('content', '🔥 Esquentada por ' || quem || ' às ' || agora_t || ' (' || coalesce(o.motivo, o.codigo) || ') — a conversa segue com o time (venda em andamento).'));
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (c.id, 'sistema', '[🔥 esquentada no NIOGEN por ' || quem || ' — segue com o time (venda em andamento)]', false);
      r := jsonb_build_object('ok', true, 'acao_id', aid, 'assumiu', false, 'resumo', '✓ mensagem enviada · a conversa segue com o time (venda em andamento)');
    else
      perform public._bo_enfileirar(g, 4, 'oportunidade', c.venda_id, c, 'desatribuir', jsonb_build_object('team_id', null));
      update public.mari_conversas set humano_atribuido = false, time_atribuido = false where id = c.id;
      if c.status = 'handoff_realizado' then perform public._mari_fechar_ciclo(c.id, '🔥 esquentada sem assumir — a Mari segue'); end if;
      perform public._bo_enfileirar(g, 2, 'oportunidade', c.venda_id, c, 'nota',
        jsonb_build_object('content', '🔥 Esquentada por ' || quem || ' às ' || agora_t || ' (' || coalesce(o.motivo, o.codigo) || ') — a Mari segue (time retirado).'));
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (c.id, 'sistema', '[🔥 esquentada no NIOGEN por ' || quem || ' — a Mari segue]', false);
      r := jsonb_build_object('ok', true, 'acao_id', aid, 'assumiu', false, 'resumo', '✓ mensagem enviada · a Mari segue a conversa');
    end if;
  end if;

  insert into public.oportunidades_log (conversa_id, codigo, tipo, motivo, assumiu, canal, valor_mes, pontos, detalhe)
  values (p_conversa, o.codigo, 'enviada', o.motivo, coalesce(p_assumir, false), case when p_template is null then 'livre' else 'template' end,
          o.valor_mes, o.pontos,
          jsonb_strip_nulls(jsonb_build_object('regras', to_jsonb(o.regras), 'template', p_template,
            'editado', case when p_template is null then txt is distinct from btrim(coalesce(o.texto_sugerido, '')) end,
            'acao_id', r ->> 'acao_id')));
  return r || jsonb_build_object('oportunidade', o.codigo);
end $$;

create or replace function public._conversas_volta_mari() returns int
language plpgsql security definer set search_path = public as $$
declare
  c   public.mari_conversas;
  g   uuid;
  n   int := 0;
begin
  for c in
    select m.* from public.mari_conversas m
     where m.canal = 'whatsapp' and m.chatwoot_conversation_id is not null
       and (m.chatwoot_status = 'resolved' or (m.chatwoot_status = 'snoozed' and m.funil_destino in ('ja_cliente_nio', 'ja_cliente')))
       and (m.chatwoot_time is not null or m.chatwoot_agente is not null or coalesce(m.humano_atribuido, false) or coalesce(m.time_atribuido, false))
       and not coalesce(m.nao_contatar, false)
       and not (coalesce(m.chatwoot_etiquetas, '{}') && array['nao-contatar', 'suporte-nio'])
       and coalesce(m.quadro_encerrada_motivo, '') <> 'suporte_nio'
       and (coalesce(m.funil_destino, '') not in ('ja_cliente_nio', 'ja_cliente', 'instalada')
            -- 0227 (D2): já é cliente Nio fica com o time enquanto há conversa; 72 h sem ninguém falar → o ciclo fecha
            -- (se voltar a escrever, a Mari vê a Saída e passa para o time — cliente Nio é humano)
            or (m.funil_destino in ('ja_cliente_nio', 'ja_cliente')
                and greatest(m.ultima_msg_lead_at, m.ultima_msg_mari_at, m.created_at) < now() - interval '72 hours'
                and not exists (select 1 from public.mari_turnos t2 where t2.conversa_id = m.id and t2.papel = 'humano'
                                 and t2.created_at > now() - interval '72 hours')))
       and (m.venda_id is null or exists (select 1 from public.vendas v where v.id = m.venda_id and v.status = 'saida'))
       and greatest(m.ultima_msg_lead_at, m.ultima_msg_mari_at, m.created_at) < now() - interval '24 hours'
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = m.id and t.papel = 'humano'
                        and t.created_at > now() - interval '24 hours')
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.momento = 'volta_mari'
                        and a.criada_em > greatest(m.ultima_msg_lead_at, m.ultima_msg_mari_at, m.created_at))
     limit 20
     for update skip locked
  loop
    g := gen_random_uuid();
    update public.mari_conversas set humano_atribuido = false, time_atribuido = false, chatwoot_agente = null, chatwoot_time = null
     where id = c.id;
    if c.status = 'handoff_realizado' then
      perform public._mari_fechar_ciclo(c.id, 'janela de 24 h fechada com o time — volta para a Mari');
    end if;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[janela de 24 h fechada com o time e sem venda viva — a conversa volta para a Mari; se o cliente escrever, ela atende]', false);
    perform public._bo_enfileirar(g, 1, 'volta_mari', c.venda_id, c, 'etiquetas',
      jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
    perform public._bo_enfileirar(g, 2, 'volta_mari', c.venda_id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
    perform public._bo_enfileirar(g, 3, 'volta_mari', c.venda_id, c, 'desatribuir', jsonb_build_object('team_id', null));
    perform public._bo_enfileirar(g, 4, 'volta_mari', c.venda_id, c, 'nota',
      jsonb_build_object('content', '↩ NIOGEN · janela de 24 h fechada sem venda viva: a conversa volta para a Mari. Se o cliente voltar a escrever, ela atende. Para seguir com o time, assuma de novo.'));
    -- o enfileirar toca a conversa; a marca de "já devolvida" é a própria ação volta_mari (não repete até alguém falar de novo)
    n := n + 1;
  end loop;
  return n;
end;
$$;

create or replace function public._nao_contatar_etiqueta()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(new.nao_contatar, false) or coalesce(old.nao_contatar, false) then return null; end if;
  -- 0227 (D9): a exceção da recusa saiu — desde a 0189 só quem pede para parar fica "não contatar", e aí a etiqueta vale sempre
  if coalesce(new.canal, '') <> 'whatsapp' or coalesce(new.chatwoot_conversation_id, '') = '' or coalesce(new.telefone, '') like '5500000000%' then return null; end if;
  if 'nao-contatar' = any (coalesce(new.chatwoot_etiquetas, '{}'::text[])) then return null; end if;
  if exists (select 1 from public.chatwoot_acoes a where a.conversa_id = new.id and a.tipo = 'etiquetas'
               and a.payload -> 'add' ? 'nao-contatar' and a.criada_em > now() - interval '10 minutes') then return null; end if;
  perform public._bo_enfileirar(gen_random_uuid(), 1, 'nao_contatar', new.venda_id, new, 'etiquetas',
    jsonb_build_object('add', jsonb_build_array('nao-contatar')));
  perform public._bo_enfileirar(gen_random_uuid(), 2, 'nao_contatar', new.venda_id, new, 'nota',
    jsonb_build_object('content', '🚫 Não contatar: o cliente pediu para parar. A Mari e os lembretes param de vez. Nunca mais chamar.'));
  return null;
exception when others then
  insert into public.mari_erros (conversa_id, no_n8n, mensagem) values (new.id, '_nao_contatar_etiqueta', sqlerrm);
  return null;
end;
$$;

create or replace function public.mari_chatwoot_sync(
  p_chatwoot_conversation_id text,
  p_status    text,
  p_agente    text,
  p_time      text,
  p_etiquetas text[]
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  if coalesce(btrim(p_chatwoot_conversation_id), '') = '' then
    return 0;
  end if;
  update public.mari_conversas
     set chatwoot_status    = case when p_status in ('open', 'pending', 'resolved', 'snoozed') then p_status else chatwoot_status end,
         chatwoot_agente    = nullif(btrim(coalesce(p_agente, '')), ''),
         chatwoot_time      = nullif(btrim(coalesce(p_time, '')), ''),
         chatwoot_etiquetas = coalesce(p_etiquetas, '{}'),
         -- 0227 (D3): sem pessoa/time no Chatwoot → desmarca (salvo atribuição do NIOGEN ainda na fila)
         humano_atribuido = case when nullif(btrim(coalesce(p_agente, '')), '') is not null then true
                                 when exists (select 1 from public.chatwoot_acoes a where a.conversa_id = mari_conversas.id and a.tipo = 'atribuir'
                                               and a.status in ('pendente', 'executando') and a.payload ? 'assignee_id') then humano_atribuido
                                 else false end,
         time_atribuido = case when nullif(btrim(coalesce(p_time, '')), '') is not null then true
                               when exists (select 1 from public.chatwoot_acoes a where a.conversa_id = mari_conversas.id and a.tipo = 'atribuir'
                                             and a.status in ('pendente', 'executando')) then time_atribuido
                               else false end,
         chatwoot_sync_em   = now()
   where chatwoot_conversation_id = btrim(p_chatwoot_conversation_id)
     and canal = 'whatsapp';
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ── D3: ação "desatribuir" feita pelo NIOGEN no Chatwoot → o banco espelha na hora ──
create or replace function public._cw_espelho_dono() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.tipo <> 'desatribuir' or new.status <> 'feita' or old.status = 'feita' then return null; end if;
  if new.payload ? 'assignee_id' and new.payload ->> 'assignee_id' is null then
    update public.mari_conversas set humano_atribuido = false, chatwoot_agente = null where id = new.conversa_id;
  end if;
  if new.payload ? 'team_id' and new.payload ->> 'team_id' is null then
    update public.mari_conversas set time_atribuido = false, chatwoot_time = null where id = new.conversa_id;
  end if;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_cw_espelho_dono', sqlerrm);
  return null;
end;
$$;
revoke all on function public._cw_espelho_dono() from public, anon, authenticated;
drop trigger if exists chatwoot_acoes_espelho_dono on public.chatwoot_acoes;
create trigger chatwoot_acoes_espelho_dono after update of status on public.chatwoot_acoes
  for each row when (new.tipo = 'desatribuir' and new.status = 'feita') execute function public._cw_espelho_dono();

-- ── D8 / D12: a venda foi para Saída por outro caminho (cancelamento da Nio no OSAB, operador) → a conversa volta para a Mari
-- na hora, igual à Saída manual (0224). Não contatar e já é cliente Nio ficam como estão. A Saída manual marca a transação
-- (niogen.saida_manual) e já faz isso ela mesma.
create or replace function public._venda_saida_devolver(p_venda uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  vv  public.vendas;
  c   public.mari_conversas;
  g   uuid;
  n   int := 0;
begin
  select * into vv from public.vendas where id = p_venda;
  if vv.id is null or vv.status <> 'saida' then return 0; end if;
  for c in select * from public.mari_conversas m
            where m.venda_id = vv.id and m.canal = 'whatsapp' and not coalesce(m.nao_contatar, false)
              and coalesce(m.funil_destino, '') not in ('ja_cliente_nio', 'ja_cliente')
              and (coalesce(m.humano_atribuido, false) or coalesce(m.time_atribuido, false) or m.chatwoot_agente is not null
                   or m.chatwoot_time is not null or m.status = 'handoff_realizado')
  loop
    update public.mari_conversas set humano_atribuido = false, time_atribuido = false where id = c.id;
    if c.status = 'handoff_realizado' then
      perform public._mari_fechar_ciclo(c.id, 'venda em Saída (' || coalesce(vv.motivo_saida, 'sem motivo') || ') — a conversa volta para a Mari');
    end if;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[venda em Saída — ' || coalesce(vv.motivo_saida, 'sem motivo') || ' — a conversa voltou para a Mari]', false);
    if coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%' then
      g := gen_random_uuid();
      perform public._bo_enfileirar(g, 1, 'saida_devolver', vv.id, c, 'etiquetas',
        jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
      perform public._bo_enfileirar(g, 2, 'saida_devolver', vv.id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      perform public._bo_enfileirar(g, 3, 'saida_devolver', vv.id, c, 'desatribuir', jsonb_build_object('team_id', null));
      perform public._bo_enfileirar(g, 4, 'saida_devolver', vv.id, c, 'nota',
        jsonb_build_object('content', '↩ Venda em Saída (' || coalesce(vv.motivo_saida, 'sem motivo') || ') — a conversa voltou para a Mari. Se o cliente escrever, ela responde.'));
    end if;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function public._venda_saida_devolver(uuid) from public, anon, authenticated;

create or replace function public._venda_saida_devolve() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('niogen.saida_manual', true), '') = '1' then return null; end if;   -- a Saída manual já devolveu
  perform public._venda_saida_devolver(new.id);
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_venda_saida_devolve', new.id::text || ': ' || sqlerrm);
  return null;
end;
$$;
revoke all on function public._venda_saida_devolve() from public, anon, authenticated;
drop trigger if exists vendas_saida_devolve on public.vendas;
create trigger vendas_saida_devolve after update of status on public.vendas
  for each row when (new.status = 'saida' and old.status is distinct from 'saida') execute function public._venda_saida_devolve();

-- ── Backfill ──
-- D3: "humano/time atribuído" no banco sem pessoa/time no Chatwoot (espelho já lido) → desmarca (caso Ivon: pessoa; o time fica)
update public.mari_conversas m set humano_atribuido = false
 where m.humano_atribuido and m.chatwoot_agente is null and m.chatwoot_sync_em is not null
   and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.tipo = 'atribuir' and a.status in ('pendente', 'executando'));
update public.mari_conversas m set time_atribuido = false
 where m.time_atribuido and m.chatwoot_time is null and m.chatwoot_agente is null and m.chatwoot_sync_em is not null
   and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.tipo = 'atribuir' and a.status in ('pendente', 'executando'));
-- D12: venda já em Saída com a conversa aberta e com dono (Mirian) → devolve agora, pelo mesmo gatilho
create temporary table _d12 on commit drop as
  select v.id from public.vendas v
   where v.status = 'saida' and exists (select 1 from public.mari_conversas m where m.venda_id = v.id and m.canal = 'whatsapp'
           and m.chatwoot_status in ('open', 'pending') and not coalesce(m.nao_contatar, false)
           and coalesce(m.funil_destino, '') not in ('ja_cliente_nio', 'ja_cliente')
           and (coalesce(m.humano_atribuido, false) or coalesce(m.time_atribuido, false) or m.chatwoot_agente is not null or m.chatwoot_time is not null));
select public._venda_saida_devolver(id) from _d12;


commit;
