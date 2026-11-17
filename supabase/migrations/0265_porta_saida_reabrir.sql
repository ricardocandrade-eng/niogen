-- NIOGEN | supabase/migrations/0265_porta_saida_reabrir.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Passo 5 do caminho (porta única), 1º grupo: SAÍDA e REABRIR — Ricardo, 17/11: "Sim, construa" (desenho + decisões a–d).
-- A porta deixa de só anotar e passa a MANDAR nestes eventos:
--   saida:* (lead_sair) · silenciar:* (backoffice_conversa_saida) · reabrir (lead_reabrir) · nao_contatar (conversa_nao_contatar)
--   · cliente_escreveu vindo de "Saída — pode voltar" (reabre) ou de "Cliente Nio" (silencia) — chamado de dentro da mari_entrada.
-- (1) config_transicao ganha "exige" (admin · cliente_escreveu_depois) e as linhas das decisões a, b e c; porta_prever devolve o "exige".
-- (2) porta(evento, conversa, venda, dados): lê a situação, pergunta à tabela, RECUSA com a frase ou aplica, numa transação só,
--     os seis efeitos da Saída (seção 7 do diagnóstico): (1) motivo, sub-motivo, volta, quem — conversa e venda juntas;
--     (2) vez de ninguém, dono limpo, ciclo da Mari fechado; (3) cadência parada (os lembretes da venda já param em Saída — 0253);
--     (4) projetor único: o Chatwoot sai da situação (resolvida/adiada, sem pessoa, sem time, sem handoff-*, com saida-<motivo>);
--     (5) pedido/OS aberta: "cancelou no portal?" — sem o sim, fica a marca "falta cancelar na Nio" (Live sem mudança — decisão d);
--     (6) a comissão prevista sai sozinha (lê o status da venda); aviso a parceiro não existe (só a Dharma) — fica o registro.
--     A volta: cliente em "pode voltar" escreve → reabre onde parou, com a Mari; despedida curta ("ok, obrigado") não reabre.
-- (3) As quatro funções do grupo viram só "validar + porta" (mesmos nomes e parâmetros — telas e extensão não mudam).
-- (4) APAGADOS: _venda_saida_devolver (a devolução da venda) e o ramo "cliente voltou a escrever" do _funil_antes; a projeção
--     no Chatwoot do _funil_depois e o corpo do _saidas_fechar dão lugar ao projetor único (_porta_projetar).
--     Ficam, para os grupos seguintes (eles ainda gravam destino ou status de venda sem a porta): os ramos venda/quadro/reabrir do
--     _funil_antes (robôs OSAB/portal/GED360, Mover do admin, quadro), o gatilho vendas_saida_devolve (agora chama a porta para
--     soltar o dono quando um robô põe a venda em Saída) e _saida_limpa_conversa/_saida_limpa_venda (limpam o motivo quando esses
--     caminhos mudam o destino; a porta escreve saida_em junto e eles não interferem).
-- Regra 20: nenhum estado novo; toda mudança deste grupo é evento na porta, com motivo e autor (turno de sistema + porta_sombra);
-- a conferência é a R12 do portão (bloqueio) e a v_porta_divergencias da produção.
begin;

-- ── (1) a tabela ──
alter table public.config_transicao add column if not exists exige text;
alter table public.config_transicao drop constraint if exists config_transicao_exige_check;
alter table public.config_transicao add constraint config_transicao_exige_check check (exige is null or exige in ('admin', 'cliente_escreveu_depois'));

delete from public.config_transicao where evento = 'silenciar:reativar';
insert into public.config_transicao (evento, de, para, aceito, frase, nota, exige) values
  ('reabrir', 'saida_definitiva', '{andamento}', true,
     'Saída definitiva só o admin reabre (crédito, biometria, fraude, Nio não instalou, teste).', 'decisão a (Ricardo, 17/11)', 'admin'),
  ('reabrir', 'nao_contatar', '{andamento}', true,
     'O cliente pediu para parar de receber mensagens. Só dá para reabrir se ele escrever de novo.', 'decisão b (17/11): como a 0189', 'cliente_escreveu_depois'),
  ('silenciar:reativar', 'cliente_nio', '{andamento,=}', true,
     'Só o admin reativa um cliente Nio silenciado (quando ele não é cliente Nio).', 'decisão c (17/11)', 'admin'),
  ('silenciar:reativar', '*', '{=}', true, null, 'não estava silenciada: nada muda', null)
on conflict (evento, de) do update set para = excluded.para, aceito = excluded.aceito, frase = excluded.frase, nota = excluded.nota, exige = excluded.exige;

drop function if exists public.porta_prever(text, text);
create function public.porta_prever(p_de text, p_evento text)
returns table (aceito boolean, para text[], frase text, regra text, exige text) language plpgsql stable set search_path = public as $$
declare
  de    text := coalesce(p_de, '(novo)');
  partes text[] := string_to_array(coalesce(p_evento, ''), ':');
  evs   text[] := array[coalesce(p_evento, '')];
  des   text[];
  e text; d text; t public.config_transicao;
begin
  for k in reverse coalesce(array_length(partes, 1), 1) - 1 .. 1 loop
    evs := evs || (array_to_string(partes[1:k], ':') || ':*');
  end loop;
  des := array_remove(array[de, public._situacao_grupo(de), '*'], null);
  foreach e in array evs || array['*'] loop
    foreach d in array des loop
      select * into t from public.config_transicao x where x.evento = e and x.de = d;
      if found then
        return query select t.aceito, t.para, t.frase, e || ' @ ' || d, t.exige;
        return;
      end if;
    end loop;
  end loop;
  return query select null::boolean, null::text[], 'sem regra na tabela para este evento nesta situação'::text, null::text, null::text;
end $$;
grant execute on function public.porta_prever(text, text) to authenticated;

-- ── (2) peças da porta ──

-- ordem ao Chatwoot sem repetir a mesma ordem na mesma transação (a porta, o gatilho da venda e o do destino podem pedir a mesma)
create or replace function public._porta_ordem(p_g uuid, p_seq int, p_origem text, c public.mari_conversas, p_tipo text, p_payload jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = p_tipo and a.payload = p_payload
               and a.status in ('pendente', 'executando') and a.criada_em >= now()) then
    return false;
  end if;
  perform public._bo_enfileirar(p_g, p_seq, p_origem, c.venda_id, c, p_tipo, p_payload);
  return true;
end $$;

-- O PROJETOR: o Chatwoot sai da situação (regra de ouro 4 — consequência é tabela). Saída, Não contatar e Cliente Nio:
-- etiqueta saida-<destino> (e suporte-nio no silêncio), sem handoff-*, sem pessoa e sem time, resolvida (adiada no silêncio).
-- Reaberto: sem etiqueta de saída; p_status diz se abre. p_lote (a varredura de 10 em 10 min): só manda o que o espelho mostra fora do lugar.
create or replace function public._porta_projetar(p_conversa uuid, p_origem text, p_nota text default null, p_status text default null,
                                                  p_lote boolean default false)
returns text[] language plpgsql security definer set search_path = public as $$
declare
  c     public.mari_conversas;
  s     text;
  g     uuid := gen_random_uuid();
  todas jsonb; lab text; etq text[];
  adds  jsonb := '[]'::jsonb; rems jsonb := '[]'::jsonb;
  sil   boolean; fim boolean; alvo text; precisa boolean;
  feito text[] := '{}';
begin
  select * into c from public.mari_conversas where id = p_conversa;
  if c.id is null or coalesce(c.canal, '') <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = ''
     or coalesce(c.telefone, '') like '5500000000%' then
    return feito;
  end if;
  s   := public._porta_situacao(c.id, null::uuid);
  fim := s in ('saida_pode_voltar', 'saida_definitiva', 'nao_contatar', 'cliente_nio');
  sil := coalesce(c.quadro_encerrada_motivo, '') = 'suporte_nio';
  etq := coalesce(c.chatwoot_etiquetas, '{}'::text[]);
  select coalesce(jsonb_agg(etiqueta), '[]'::jsonb) into todas from public.config_funil
   where parceiro_id = 'dharma' and tipo = 'destino' and etiqueta is not null;

  if fim or s = 'instalada' then
    select etiqueta into lab from public.config_funil where parceiro_id = 'dharma' and tipo = 'destino' and codigo = c.funil_destino;
    if lab is not null then adds := adds || to_jsonb(lab); end if;
    if sil then adds := adds || '"suporte-nio"'::jsonb; end if;
    rems := (todas - coalesce(lab, '')) || case when fim then '["handoff-venda", "handoff-humano"]'::jsonb else '[]'::jsonb end;
  else
    rems := todas;
  end if;
  if not sil then rems := rems || '"suporte-nio"'::jsonb; end if;
  if not coalesce(c.nao_contatar, false) then rems := rems || '"nao-contatar"'::jsonb; end if;   -- liberado no NIOGEN = sem a etiqueta
  precisa := exists (select 1 from jsonb_array_elements_text(adds) e where not (e = any (etq)))
          or exists (select 1 from jsonb_array_elements_text(rems) e where e = any (etq));
  if (precisa or (not p_lote and jsonb_array_length(adds) > 0)) then
    if public._porta_ordem(g, 1, p_origem, c, 'etiquetas', jsonb_build_object('add', adds, 'remove', rems)) then
      feito := feito || 'etiquetas'::text;
    end if;
  end if;

  if fim and (not p_lote or c.chatwoot_agente is not null or c.chatwoot_time is not null) then
    perform public._porta_ordem(g, 2, p_origem, c, 'desatribuir', jsonb_build_object('assignee_id', null));
    perform public._porta_ordem(g, 3, p_origem, c, 'desatribuir', jsonb_build_object('team_id', null));
    feito := feito || 'sem pessoa e sem time'::text;
  end if;

  if p_nota is not null then
    perform public._porta_ordem(g, 4, p_origem, c, 'nota', jsonb_build_object('content', p_nota));
    feito := feito || 'nota'::text;
  end if;

  alvo := coalesce(p_status, case when sil then 'snoozed' when fim then 'resolved' end);
  if alvo is not null
     and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'resolver'
                       and a.payload ->> 'status' = alvo and a.status in ('pendente', 'executando'))
     and (coalesce(c.chatwoot_status, 'open') <> alvo
          or exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'resolver'
                       and a.status in ('pendente', 'executando'))) then
    perform public._porta_ordem(g, 5, p_origem, c, 'resolver', jsonb_build_object('status', alvo));
    feito := feito || case alvo when 'open' then 'conversa aberta' when 'snoozed' then 'conversa adiada' else 'conversa resolvida' end;
  end if;
  return feito;
end $$;

-- efeitos 2 e 3: vez de ninguém, dono limpo, ciclo da Mari fechado, cadência parada
create or replace function public._porta_soltar(p_conversa uuid, p_porque text)
returns void language plpgsql security definer set search_path = public as $$
declare c public.mari_conversas;
begin
  select * into c from public.mari_conversas where id = p_conversa;
  if c.id is null then return; end if;
  if c.status = 'handoff_realizado' then perform public._mari_fechar_ciclo(c.id, p_porque); end if;
  update public.mari_conversas set humano_atribuido = false, time_atribuido = false, processando_ate = null where id = c.id;
  perform public.mari_cadencia_parar(c.id, p_resolvida => true);
end $$;

-- motivo de Saída (config_lead) → destino do funil
create or replace function public._porta_destino_de(p_codigo text) returns text language sql immutable set search_path = public as $$
  select case p_codigo
    when 'cidade_nao_atendida' then 'fora_area' when 'fachada_nao_atendida' then 'sem_cobertura'
    when 'ja_cliente_nio' then 'ja_cliente_nio' when 'credito_negado' then 'credito_negado'
    when 'reprovado_biometria' then 'reprovado_biometria' when 'sem_resposta' then 'sem_resposta'
    when 'teste_duplicada' then 'teste_duplicada' else 'recusou' end   -- recusou, não contatar, Nio não instalou, fraude
$$;

-- SAÍDA (os seis efeitos)
create or replace function public._porta_sair(c public.mari_conversas, v public.vendas, p_codigo text, p_dados jsonb, p_quem text, p_pede_sub boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  k       public.config_lead;
  sub     text := nullif(btrim(coalesce(p_dados ->> 'sub', '')), '');
  volta   date := nullif(p_dados ->> 'volta', '')::date;
  obs     text := nullif(btrim(coalesce(p_dados ->> 'obs', '')), '');
  cancelou boolean := (p_dados ->> 'cancelou_portal')::boolean;
  aberto  boolean := false;
  quadro  text;
  nc_novo boolean := false;
  feito   text[] := '{}';
  nota    text;
  agora_t text := to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
begin
  select * into k from public.config_lead where parceiro_id = 'dharma' and tipo = 'saida' and codigo = p_codigo;
  if not found then raise exception 'Motivo de saída desconhecido: %', p_codigo; end if;
  if p_pede_sub and k.codigo = 'recusou' and sub is null then
    raise exception 'Diga o porquê da recusa: preço, concorrente, momento, desistiu ou outro.';
  end if;
  if volta is not null and volta <= (now() at time zone 'America/Sao_Paulo')::date then raise exception 'A data de volta precisa ser futura.'; end if;

  -- efeito 1 (venda) e 5
  if v.id is not null then
    if v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') then
      raise exception 'Venda instalada não vai para Saída. Cancelamento depois de instalar vem do OSAB.';
    end if;
    aberto := nullif(btrim(v.nio_pedido), '') is not null or nullif(btrim(v.nio_os), '') is not null;
    if aberto and cancelou is null then
      raise exception 'Esta venda tem pedido aberto na Nio. Diga se o pedido já foi cancelado no portal.';
    end if;
    update public.vendas
       set status = 'saida', motivo_saida = k.nome || coalesce(' · ' || sub, '') || coalesce(' — ' || obs, ''),
           interesse_futuro_em = volta, saida_motivo = k.codigo, saida_sub = sub
     where id = v.id;
    if aberto and cancelou then
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'cancelado_no_portal', jsonb_build_object('quando', 'na saída'), auth.uid());
    end if;
  elsif k.codigo in ('reprovado_biometria', 'nio_nao_instalou', 'venda_indevida_fraude') then
    raise exception 'Esse motivo só vale para lead com venda.';
  end if;
  feito := feito || ('Saída · ' || k.nome)::text;
  if aberto and cancelou then feito := feito || 'pedido cancelado no portal (confirmado)'::text;
  elsif aberto then feito := feito || 'falta cancelar o pedido na Nio — a linha fica na Live até confirmar'::text; end if;

  if c.id is not null then
    -- efeito 1 (conversa, junto com a venda)
    quadro := case k.codigo when 'cidade_nao_atendida' then 'fora_area' when 'fachada_nao_atendida' then 'sem_cobertura'
                            when 'nao_contatar' then 'recusou' else k.codigo end;
    nc_novo := k.codigo = 'nao_contatar' and not coalesce(c.nao_contatar, false);
    update public.mari_conversas
       set funil_destino = public._porta_destino_de(k.codigo),
           funil_detalhe = case when k.codigo = 'nao_contatar' then 'não contatar' else 'Saída: ' || k.nome end,
           funil_destino_em = now(), funil_alerta = null, funil_alerta_em = null,
           saida_motivo = k.codigo, saida_sub = sub, saida_volta_em = volta, saida_em = now(),
           quadro_encerrada_motivo = case when v.id is null then quadro else quadro_encerrada_motivo end,
           quadro_encerrada_em = case when v.id is null then now() else quadro_encerrada_em end,
           quadro_encerrada_por = case when v.id is null then auth.uid() else quadro_encerrada_por end,
           nao_contatar = coalesce(nao_contatar, false) or k.codigo = 'nao_contatar',
           credito_resultado = case when k.codigo = 'credito_negado' then 'negado' else credito_resultado end,
           credito_em = case when k.codigo = 'credito_negado' then coalesce(credito_em, now()) else credito_em end,
           processando_ate = null
     where id = c.id;
    if nc_novo then
      insert into public.mari_turnos (conversa_id, papel, texto, pendente) values (c.id, 'sistema', '[não contatar — saída registrada no NIOGEN]', false);
    end if;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[Saída "' || k.nome || '" registrada no NIOGEN por ' || p_quem || ' — vez de ninguém, sem dono'
            || case when k.codigo = 'nao_contatar' then '; ninguém fala com o cliente]'
                    when public.lead_situacao('x', 'saida', k.codigo, false, null) = 'saida_pode_voltar' then '; se o cliente escrever, a Mari responde]'
                    else ']' end, false);
    -- efeitos 2 e 3
    perform public._porta_soltar(c.id, 'Saída "' || k.nome || '" registrada no NIOGEN');
    feito := feito || 'vez de ninguém, sem dono'::text || 'cadência parada'::text;
    -- efeito 4
    nota := case when k.codigo = 'nao_contatar' then '🚫 Saída · ' || k.nome || ' — ' || p_quem || ', ' || agora_t || '. Ninguém fala com este cliente.'
                 when public.lead_situacao('x', 'saida', k.codigo, false, null) = 'saida_pode_voltar'
                   then '⛔ Saída · ' || k.nome || ' — ' || p_quem || ', ' || agora_t || '. Sem dono. Se o cliente escrever de novo, a Mari responde.'
                 else '⛔ Saída · ' || k.nome || ' — ' || p_quem || ', ' || agora_t || '. Saída definitiva: não reabre.' end;
    feito := feito || public._porta_projetar(c.id, 'saida', nota);
  end if;
  if volta is not null then feito := feito || ('volta para a Live em ' || to_char(volta, 'DD/MM'))::text; end if;
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'pedido_aberto', aberto and not coalesce(cancelou, false),
                            'resumo', '✓ ' || array_to_string(feito, ' · '));
end $$;

-- REABRIR (botão do time, ou o cliente que volta a escrever em "pode voltar")
create or replace function public._porta_reabrir(c public.mari_conversas, v public.vendas, p_quem text, p_cliente boolean, p_nc boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  novo text; d jsonb; feito text[] := '{}'; tinha_saida boolean := false;
begin
  if v.id is not null and v.status = 'saida' then
    novo := case when nullif(btrim(v.nio_os), '') is null then '0_qualificado'
                 when v.instalacao_agendada_para is not null then '2_aguardando_instalacao' else '1_vendido' end;
    update public.vendas set status = novo, interesse_futuro_em = null, saida_motivo = null, saida_sub = null where id = v.id;   -- as travas da venda valem
    feito := feito || ('venda de volta em ' || novo)::text;
  end if;
  if c.id is not null then
    tinha_saida := coalesce(c.funil_destino, 'em_andamento') <> 'em_andamento';
    if c.status = 'handoff_realizado' and not coalesce(c.humano_atribuido, false) and c.chatwoot_agente is null
       and (c.handoff_motivo in ('recusa_compra', 'sem_contato') or (not coalesce(c.time_atribuido, false) and c.chatwoot_time is null)) then
      perform public._mari_fechar_ciclo(c.id, case when p_cliente then 'cliente voltou a escrever depois da saída' else 'reaberto no NIOGEN' end);
    end if;
    update public.mari_conversas
       set funil_destino = 'em_andamento', funil_detalhe = case when p_cliente then 'cliente voltou a escrever' else 'reaberto no NIOGEN' end,
           funil_destino_em = now(),
           quadro_encerrada_motivo = null, quadro_encerrada_em = null, quadro_encerrada_por = null,
           saida_motivo = null, saida_sub = null, saida_volta_em = null, saida_em = null,
           nao_contatar = false, chatwoot_resolvida = false,
           cadencia_retorno_em = now()   -- 0255 (H8): a escada da Mari recomeça de agora
     where id = c.id
    returning * into c;
    -- 0227 (D5): a regra dura continua valendo (CEP fora da área, sem cobertura, já é cliente Nio) → não reabre
    d := public._funil_calcular(c);
    if d ->> 'duro' in ('fora_area', 'sem_cobertura', 'ja_cliente_nio') then
      raise exception '%', case d ->> 'duro'
        when 'fora_area' then 'Não reabre: o CEP deste lead continua fora da área. Corrija o CEP/endereço na ficha e depois reabra.'
        when 'sem_cobertura' then 'Não reabre: a viabilidade deste endereço continua sem cobertura. Refaça a viabilidade (ou corrija o endereço) e depois reabra.'
        else 'Não reabre: este cliente consta como já cliente Nio. Se não for, corrija na ficha e depois reabra.' end;
    end if;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', case when p_cliente then '[cliente voltou a escrever depois da Saída — reaberto onde parou, com a Mari]'
                                  else '[reaberto no NIOGEN por ' || p_quem || case when p_nc then ' — "não contatar" retirado' else '' end || ']' end, false);
    feito := feito || 'reaberto'::text;
    if p_nc then feito := feito || '"não contatar" retirado'::text; end if;
    feito := feito || public._porta_projetar(c.id, case when p_cliente then 'cliente_voltou' else 'reabrir' end, null, 'open');
  end if;
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito),
                            'resumo', '✓ reaberto' || coalesce(' — venda de volta em ' || novo, '') || case when p_nc then ' · "não contatar" retirado' else '' end);
end $$;

-- SILENCIAR cliente Nio (botão do time, ou o cliente Nio que insiste depois da despedida — 0261)
create or replace function public._porta_silenciar(c public.mari_conversas, p_quem text, p_cliente boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare feito text[] := '{}'; agora_t text := to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
begin
  update public.mari_conversas
     set quadro_encerrada_motivo = 'suporte_nio', quadro_encerrada_em = now(), quadro_encerrada_por = auth.uid(),
         funil_destino = 'ja_cliente_nio', funil_detalhe = 'suporte Nio', funil_alerta = null, funil_alerta_em = null,
         funil_destino_em = case when coalesce(funil_destino, '') = 'ja_cliente_nio' then funil_destino_em else now() end,
         saida_motivo = 'ja_cliente_nio', saida_em = coalesce(saida_em, now()), processando_ate = null
   where id = c.id;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', case when p_cliente
    then '[cliente Nio insistiu depois da despedida — silenciada sozinha (0261): ninguém responde, canais oficiais da Nio]'
    else '[silenciada no NIOGEN por ' || p_quem || ' — cliente Nio, suporte/reclamação: não é venda]' end, false);
  perform public._porta_soltar(c.id, 'cliente Nio silenciado');
  feito := feito || 'fora do Live (mesmo se ele escrever)'::text || 'cadência parada'::text || 'sem dono (ninguém atende — a Mari cala)'::text;
  feito := feito || public._porta_projetar(c.id, 'silenciar', case when p_cliente
    then '📵 Silenciada sozinha: cliente que já é Nio insistiu depois da despedida da Mari. Somos revenda — sem alçada para atender cliente Nio. '
         || 'Canais oficiais: App Nio ou 0800 001 1000. Ninguém responde por aqui.'
    else '📵 Silenciada por ' || p_quem || ' em ' || agora_t || ': cliente Nio com suporte/reclamação — não é venda (somos revenda, '
         || 'não o suporte da Nio). Canal da Nio: App Nio ou 0800. A Mari não responde e a conversa não volta para o Live (fica em Conversas › Todas, com o selo 📵). '
         || 'Para desfazer: o admin, na ficha da conversa no NIOGEN → Reativar.' end);
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'resumo', '✓ silenciada: a Mari não responde e ela não volta para o Live');
end $$;

-- REATIVAR (desfaz o silêncio de cliente Nio — só o admin, decisão c)
create or replace function public._porta_reativar(c public.mari_conversas, p_quem text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d jsonb; feito text[] := '{}'; agora_t text := to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'); volta boolean;
begin
  if coalesce(c.quadro_encerrada_motivo, '') <> 'suporte_nio' then
    return jsonb_build_object('ok', true, 'feito', '[]'::jsonb, 'resumo', 'A conversa não estava silenciada.');
  end if;
  update public.mari_conversas set quadro_encerrada_motivo = null, quadro_encerrada_em = null, quadro_encerrada_por = null
   where id = c.id returning * into c;
  d := public._funil_calcular(c);
  volta := d ->> 'duro' is null;   -- não consta mais como cliente Nio → volta ao andamento, com a Mari
  if volta then
    update public.mari_conversas
       set funil_destino = 'em_andamento', funil_detalhe = 'reativada no NIOGEN', funil_destino_em = now(),
           saida_motivo = null, saida_sub = null, saida_volta_em = null, saida_em = null, chatwoot_resolvida = false, cadencia_retorno_em = now()
     where id = c.id;
  end if;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[reativada no NIOGEN por ' || p_quem || ' — não é cliente Nio]', false);
  feito := feito || 'silêncio desfeito'::text;
  feito := feito || public._porta_projetar(c.id, 'reativar',
    '🔔 Reativada por ' || p_quem || ' em ' || agora_t || ' — não é cliente Nio. '
    || case when volta then 'A Mari volta a atender.' else 'Ainda consta como cliente Nio na ficha: corrija lá para a Mari voltar.' end,
    case when volta then 'open' end);
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'resumo', '✓ reativada' || case when volta then ': a Mari volta a atender' else '' end);
end $$;

-- NÃO CONTATAR (no que toca a Saída: sem venda viva, o lead sai — situação 14; com venda viva a venda segue sem mensagens — H1)
create or replace function public._porta_nao_contatar(c public.mari_conversas, v public.vendas, p_origem text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare feito text[] := '{}';
begin
  update public.mari_conversas set nao_contatar = true, processando_ate = null where id = c.id and not coalesce(nao_contatar, false);
  if found then
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[não contatar — ' || coalesce(p_origem, 'pedido do cliente') || ']', false);
    feito := feito || 'não contatar'::text;
  end if;
  if v.id is null or v.status = 'saida' then
    update public.mari_conversas
       set funil_destino = case when coalesce(funil_destino, 'em_andamento') = 'em_andamento' then 'recusou' else funil_destino end,
           funil_detalhe = case when coalesce(funil_destino, 'em_andamento') in ('em_andamento', 'recusou', 'sem_resposta') then 'não contatar' else funil_detalhe end,
           funil_destino_em = case when coalesce(funil_destino, 'em_andamento') = 'em_andamento' then now() else funil_destino_em end,
           funil_alerta = null, funil_alerta_em = null,
           saida_motivo = case when coalesce(funil_destino, 'em_andamento') in ('em_andamento', 'recusou', 'sem_resposta') then 'nao_contatar' else saida_motivo end,
           saida_em = coalesce(saida_em, now())
     where id = c.id;
    perform public._porta_soltar(c.id, 'não contatar');
    feito := feito || 'vez de ninguém, sem dono'::text || public._porta_projetar(c.id, 'nao_contatar');
  end if;
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito));
end $$;

-- A PORTA
create or replace function public.porta(p_evento text, p_conversa uuid, p_venda uuid, p_dados jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c       public.mari_conversas;
  v       public.vendas;
  r       record;
  antes   text;
  fam     text := split_part(coalesce(p_evento, ''), ':', 1);
  arg     text := nullif(split_part(coalesce(p_evento, ''), ':', 2), '');
  cliente boolean := p_evento = 'cliente_escreveu';
  quem    text;
  v_opt   timestamptz;
  res     jsonb;
  saidas  jsonb := '{"perdida": "recusou", "recusou": "recusou", "fora_area": "cidade_nao_atendida", "sem_cobertura": "fachada_nao_atendida",
                     "ja_cliente": "ja_cliente_nio", "ja_cliente_nio": "ja_cliente_nio", "credito_negado": "credito_negado",
                     "sem_resposta": "sem_resposta", "teste_duplicada": "teste_duplicada"}'::jsonb;   -- silenciar:<motivo antigo> → motivo de Saída
begin
  if p_conversa is not null then
    select * into c from public.mari_conversas where id = p_conversa for update;
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
  quem := coalesce((select u.nome from public.usuarios u where u.id = auth.uid()),
                   case when cliente then 'o cliente' when auth.role() = 'service_role' then 'o sistema' else 'alguém do time' end);

  -- a tabela manda: recusa com a frase, ou segue
  antes := public._porta_situacao(c.id, v.id);
  select * into r from public.porta_prever(antes, p_evento);
  if r.aceito is not true then
    if cliente then return jsonb_build_object('ok', false, 'situacao', antes, 'frase', r.frase); end if;
    raise exception '%', coalesce(r.frase, 'Esta ação não vale nesta situação (' || antes || ').');
  end if;
  if r.exige = 'admin' and coalesce(public.meu_perfil(), '') <> 'admin' then
    raise exception '%', r.frase using errcode = '42501';
  end if;
  if r.exige = 'cliente_escreveu_depois' and c.id is not null then
    select max(t.created_at) into v_opt from public.mari_turnos t
     where t.conversa_id = c.id and t.papel = 'sistema' and t.texto like '[não contatar — cliente escreveu:%';
    if v_opt is not null and not exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' and t.created_at > v_opt) then
      raise exception '%', r.frase;
    end if;
  end if;

  perform set_config('porta.aplicando', '1', true);   -- os gatilhos antigos do funil não decidem por cima da porta
  if fam = 'saida' then
    res := public._porta_sair(c, v, arg, p_dados, quem, true);
  elsif fam = 'silenciar' and arg = 'suporte_nio' then
    res := public._porta_silenciar(c, quem, false);
  elsif fam = 'silenciar' and arg = 'reativar' then
    res := public._porta_reativar(c, quem);
  elsif fam = 'silenciar' and saidas ? arg then
    res := public._porta_sair(c, v, saidas ->> arg, p_dados, quem, false);
  elsif fam = 'reabrir' then
    res := public._porta_reabrir(c, v, quem, false, coalesce(c.nao_contatar, false));
  elsif fam = 'nao_contatar' then
    res := public._porta_nao_contatar(c, v, p_dados ->> 'origem');
  elsif cliente and p_dados ->> 'acao' = 'reabrir' and antes = 'saida_pode_voltar' then
    res := public._porta_reabrir(c, v, quem, true, false);
  elsif cliente and p_dados ->> 'acao' = 'silenciar' and antes = 'cliente_nio' then
    res := public._porta_silenciar(c, quem, true);
  else
    perform set_config('porta.aplicando', '', true);
    if cliente then return jsonb_build_object('ok', false, 'situacao', antes); end if;
    raise exception 'Evento ainda não passa pela porta: %', p_evento;
  end if;
  perform set_config('porta.aplicando', '', true);
  return res;
end $$;
revoke execute on function public.porta(text, uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.porta(text, uuid, uuid, jsonb) to service_role;
revoke execute on function public._porta_ordem(uuid, int, text, public.mari_conversas, text, jsonb) from public, anon, authenticated;
revoke execute on function public._porta_projetar(uuid, text, text, text, boolean) from public, anon, authenticated;
revoke execute on function public._porta_soltar(uuid, text) from public, anon, authenticated;
revoke execute on function public._porta_sair(public.mari_conversas, public.vendas, text, jsonb, text, boolean) from public, anon, authenticated;
revoke execute on function public._porta_reabrir(public.mari_conversas, public.vendas, text, boolean, boolean) from public, anon, authenticated;
revoke execute on function public._porta_silenciar(public.mari_conversas, text, boolean) from public, anon, authenticated;
revoke execute on function public._porta_reativar(public.mari_conversas, text) from public, anon, authenticated;
revoke execute on function public._porta_nao_contatar(public.mari_conversas, public.vendas, text) from public, anon, authenticated;

-- ── (3) as quatro funções do grupo: validar e entrar pela porta (as cascas de 0263 continuam anotando) ──
create or replace function public.lead_sair__nucleo(p_conversa uuid, p_venda uuid, p_motivo text, p_sub text DEFAULT NULL::text, p_volta date DEFAULT NULL::date,
                                                    p_obs text DEFAULT NULL::text, p_cancelou_portal boolean DEFAULT NULL::boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare perfil text := coalesce(public.meu_perfil(), ''); v public.vendas;
begin
  -- 0265: a Saída é da porta (porta 'saida:<motivo>'). Aqui só quem pode e o motivo.
  if perfil not in ('admin', 'backoffice', 'vendedor') then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if not exists (select 1 from public.config_lead where parceiro_id = 'dharma' and tipo = 'saida' and codigo = p_motivo) then
    raise exception 'Motivo de saída desconhecido: %', p_motivo;
  end if;
  if perfil = 'vendedor' then
    select * into v from public.vendas
     where id = coalesce(p_venda, (select m.venda_id from public.mari_conversas m where m.id = p_conversa));
    if v.id is null or auth.uid() not in (v.vendedor_id, v.criado_por) then
      raise exception 'Vendedor só registra a saída da própria venda.' using errcode = '42501';
    end if;
  end if;
  return public.porta('saida:' || p_motivo, p_conversa, p_venda,
    jsonb_build_object('sub', p_sub, 'volta', p_volta, 'obs', p_obs, 'cancelou_portal', p_cancelou_portal));
end $$;
revoke execute on function public.lead_sair__nucleo(uuid, uuid, text, text, date, text, boolean) from public, anon, authenticated;

create or replace function public.backoffice_conversa_saida__nucleo(p_conversa uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.mari_conversas;
begin
  -- 0265: Saída/silenciar da conversa sem venda é da porta (porta 'silenciar:<motivo>'). Aqui só quem pode e o motivo.
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null and p_motivo <> 'reativar' then
    raise exception 'Esta conversa já tem venda: use a Saída da venda.';
  end if;
  if p_motivo is null or p_motivo not in ('perdida', 'recusou', 'fora_area', 'ja_cliente', 'ja_cliente_nio', 'sem_cobertura', 'credito_negado',
                                          'sem_resposta', 'teste_duplicada', 'suporte_nio', 'reativar') then
    raise exception 'Motivo desconhecido: %', p_motivo;
  end if;
  return public.porta('silenciar:' || p_motivo, p_conversa, null, '{}'::jsonb);
end $$;
revoke execute on function public.backoffice_conversa_saida__nucleo(uuid, text) from public, anon, authenticated;

create or replace function public.lead_reabrir__nucleo(p_conversa uuid, p_venda uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  -- 0265: Reabrir é da porta (situação × evento decide: Saída "pode voltar" reabre; definitiva só o admin; Não contatar só se o cliente escreveu).
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then raise exception 'Só admin ou backoffice.' using errcode = '42501'; end if;
  return public.porta('reabrir', p_conversa, p_venda, '{}'::jsonb);
end $$;
revoke execute on function public.lead_reabrir__nucleo(uuid, uuid) from public, anon, authenticated;

create or replace function public.conversa_nao_contatar__nucleo(p_conversa uuid, p_origem text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  -- 0265: Não contatar é da porta (sem venda viva, o lead sai — situação 14; com venda viva, a venda segue sem mensagens — H1).
  if auth.role() is distinct from 'service_role' and coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  return public.porta('nao_contatar', p_conversa, null, jsonb_build_object('origem', p_origem)) || '{"ok": true}'::jsonb;
end $$;
revoke execute on function public.conversa_nao_contatar__nucleo(uuid, text) from public, anon, authenticated;

-- ── (4) os gatilhos antigos do grupo ──

-- a devolução da venda em Saída por outro caminho (robô do OSAB/portal/GED360, Mover do admin, biometria negada): agora pela porta
create or replace function public._venda_saida_devolve()
returns trigger language plpgsql security definer set search_path = public as $$
declare c public.mari_conversas;
begin
  if coalesce(current_setting('porta.aplicando', true), '') = '1' then return null; end if;   -- a Saída pela porta já fez tudo
  for c in select * from public.mari_conversas m
            where m.venda_id = new.id and m.canal = 'whatsapp'
              and (coalesce(m.humano_atribuido, false) or coalesce(m.time_atribuido, false) or m.chatwoot_agente is not null
                   or m.chatwoot_time is not null or m.status = 'handoff_realizado')
  loop
    perform public._porta_soltar(c.id, 'venda em Saída (' || coalesce(new.motivo_saida, 'sem motivo') || ')');
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[venda em Saída — ' || coalesce(new.motivo_saida, 'sem motivo') || ' — vez de ninguém, sem dono]', false);
    perform public._porta_projetar(c.id, 'saida_devolver',
      '↩ Venda em Saída (' || coalesce(new.motivo_saida, 'sem motivo') || ') — sem dono. Se o cliente escrever, a Mari responde.');
  end loop;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_venda_saida_devolve', new.id::text || ': ' || sqlerrm);
  return null;
end $$;
drop function if exists public._venda_saida_devolver(uuid);

-- funil: a porta escreve o destino; o gatilho só sobe a etapa. O ramo "cliente voltou a escrever" saiu (a porta reabre, na mari_entrada).
CREATE OR REPLACE FUNCTION public._funil_antes()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  d        jsonb;
  ev       text;
  novo     text; det text;
  ant      text := coalesce(new.funil_destino, 'em_andamento');
begin
  d := public._funil_calcular(new);
  -- etapa: só sobe
  if new.funil_etapa is null or public._funil_ordem('etapa', d ->> 'etapa') > public._funil_ordem('etapa', new.funil_etapa) then
    new.funil_etapa := d ->> 'etapa';
  end if;
  -- 0265 (passo 5): Saída, Reabrir, silenciar e Não contatar passam pela porta, que grava o destino — o gatilho não decide por cima
  if coalesce(current_setting('porta.aplicando', true), '') = '1' then
    new.funil_evento := null;
    return new;
  end if;

  -- qual fonte de evento acabou de mudar (só ela vale: um sinal velho não derruba uma conversa que o cliente reabriu)
  -- (venda/quadro/reabrir ficam para os caminhos que ainda não passam pela porta: robôs OSAB/portal/GED360, Mover do admin, quadro)
  ev := case
    when new.funil_evento = 'venda' and d ->> 'venda' is not null then 'venda'
    when tg_op = 'UPDATE' and new.quadro_encerrada_motivo is distinct from old.quadro_encerrada_motivo and d ->> 'quadro' is not null then 'quadro'
    when tg_op = 'UPDATE' and new.handoff_motivo is distinct from old.handoff_motivo and d ->> 'hand' is not null then 'hand'
    when tg_op = 'UPDATE' and new.cadencia_passo is distinct from old.cadencia_passo and d ->> 'cad' is not null then 'cad' end;

  if d ->> 'duro' is not null and (ev is null
      or public._funil_ordem('destino', d ->> 'duro') <= public._funil_ordem('destino', d ->> ev)) then
    novo := d ->> 'duro'; det := d ->> 'duro_det';
  elsif ev is not null then
    novo := d ->> ev; det := d ->> (ev || '_det');
  elsif new.funil_evento = 'reabrir' then
    novo := 'em_andamento'; det := 'venda reativada';
  elsif tg_op = 'UPDATE' and ant = 'sem_cobertura' and old.funil_detalhe = 'viabilidade: sem cobertura' then
    novo := coalesce(d ->> 'evento', 'em_andamento');                                  -- 0151: o sem cobertura era a regra dura
    det  := coalesce(d ->> 'evento_det', 'cobertura revista: operador elegível (≤ 200 m)');  -- e ela não vale mais
  elsif tg_op = 'UPDATE' and old.funil_destino is not null and ant in ('teste_duplicada', 'instalada') then
    novo := 'em_andamento'; det := 'saída dura não vale mais';
  elsif tg_op = 'UPDATE' and old.funil_destino is not null then
    novo := old.funil_destino; det := old.funil_detalhe;                 -- saída fica (quem reabre é a porta)
  else
    novo := coalesce(d ->> 'evento', 'em_andamento'); det := d ->> 'evento_det';   -- 1º cálculo (backfill / conversa nova)
  end if;

  if novo is distinct from new.funil_destino then
    new.funil_destino := novo;
    new.funil_detalhe := det;
    new.funil_destino_em := now();
    if novo = 'em_andamento' then new.chatwoot_resolvida := false; end if;   -- 0155: reabriu → a cadência volta a valer
    if novo <> 'em_andamento' then new.funil_alerta := null; new.funil_alerta_em := null; end if;   -- destino registrado: alerta some
  end if;
  new.funil_evento := null;
  return new;
exception when others then
  -- o funil nunca derruba a gravação da conversa: registra e segue sem recalcular
  insert into public.mari_erros (conversa_id, no_n8n, mensagem) values (new.id, 'funil_antes', sqlerrm);
  new.funil_evento := null;
  return new;
end;
$function$;

-- funil depois: guarda o histórico; o Chatwoot sai do projetor único (a porta projeta o que ela mesma muda)
CREATE OR REPLACE FUNCTION public._funil_depois()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if tg_op = 'UPDATE' and new.funil_destino is not distinct from old.funil_destino then
    if new.funil_etapa is distinct from old.funil_etapa then
      insert into public.funil_eventos (conversa_id, tipo, de, para) values (new.id, 'etapa', old.funil_etapa, new.funil_etapa);
    end if;
    return null;
  end if;
  insert into public.funil_eventos (conversa_id, tipo, de, para, detalhe, por)
  values (new.id, 'destino', case when tg_op = 'UPDATE' then old.funil_destino end, new.funil_destino, new.funil_detalhe, auth.uid());
  if coalesce(current_setting('porta.aplicando', true), '') = '1' then return null; end if;   -- 0265: a porta projeta no fim
  if tg_op = 'UPDATE' and coalesce(new.funil_destino, 'em_andamento') = 'em_andamento' and old.funil_destino in ('em_andamento', 'teste_duplicada') then
    return null;
  end if;
  perform public._porta_projetar(new.id, 'destino');
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_funil_depois', sqlerrm);
  return null;
end;
$function$;

-- a varredura de 10 em 10 min (indicacao_tick): Saída aberta sem ninguém com o que fazer → o projetor fecha (0249/0250, agora pela situação)
CREATE OR REPLACE FUNCTION public._saidas_fechar(p_agora timestamp with time zone DEFAULT now())
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  c     public.mari_conversas;
  ult   record;
  nosso timestamptz;
  n     int := 0;
begin
  for c in
    select m.* from public.mari_conversas m
      join public.v_lead_situacao ls on ls.conversa_id = m.id
     where m.canal = 'whatsapp' and m.chatwoot_conversation_id is not null
       and coalesce(m.chatwoot_status, 'open') = 'open'
       and ls.situacao in ('saida_pode_voltar', 'saida_definitiva', 'nao_contatar', 'cliente_nio')
       and coalesce(m.funil_destino, 'em_andamento') <> 'teste_duplicada'   -- duplicada: várias linhas da mesma conversa
       and coalesce(m.quadro_encerrada_motivo, '') <> 'suporte_nio'
       and m.chatwoot_agente is null and not coalesce(m.humano_atribuido, false) and not coalesce(m.time_atribuido, false)
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
     limit 30
     for update of m skip locked
  loop
    select t.papel, t.created_at into ult from public.mari_turnos t
     where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano') order by t.created_at desc limit 1;
    if ult.papel is null or ult.created_at > p_agora - interval '5 minutes' then continue; end if;
    -- 0250 (A6): Não contatar não reabre (situação 14: vez de ninguém) — fecha seja o que for que o cliente escreveu
    if ult.papel = 'lead' and not coalesce(c.nao_contatar, false) then
      select max(t.created_at) into nosso from public.mari_turnos t where t.conversa_id = c.id and t.papel in ('mari', 'humano');
      if nosso is null then continue; end if;
      if exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' and t.created_at > nosso
                    and (t.midia is not null or not public._saida_so_confirmacao(t.texto))) then continue; end if;
    end if;
    if array_length(public._porta_projetar(c.id, 'saida_fechar', null, null, true), 1) is null then continue; end if;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[Saída aberta sem ninguém com o que fazer (' || case when coalesce(c.nao_contatar, false) then 'Não contatar não reabre (0250)'
            when ult.papel = 'lead' then 'o cliente só confirmou ou se despediu'
            else 'a última fala é nossa' end || ') — resolvida no Chatwoot (0249); se ele escrever, reabre]', false);
    n := n + 1;
  end loop;
  return n;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_saidas_fechar', sqlerrm);
  return n;
end $function$;
revoke all on function public._saidas_fechar(timestamptz) from public, anon, authenticated;

-- mari_entrada: a volta do cliente em Saída e o silêncio do cliente Nio entram pela porta (cliente_escreveu)
CREATE OR REPLACE FUNCTION public.mari_entrada__nucleo(p_telefone text, p_nome text, p_texto text, p_canal text DEFAULT 'teste'::text, p_origem text DEFAULT NULL::text, p_chatwoot_conversation_id text DEFAULT NULL::text, p_midia jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_tel  text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_conv public.mari_conversas;
  v_ts   timestamptz := clock_timestamp();
  v_orig text := case when p_origem in ('meta_ads', 'instagram', 'facebook', 'site', 'fila_vero', 'indicacao', 'direto', 'teste') then p_origem end;
  v_cw   text := nullif(btrim(coalesce(p_chatwoot_conversation_id, '')), '');
  v_pos  boolean;
  v_opt  boolean;
  v_sil  boolean := false;   -- 0261: silenciada (cliente Nio)
  v_g    uuid;   -- 0155: cliente pediu para parar (SAIR, PARAR…)
  v_posv boolean;   -- 0155: cliente já instalado → pós-venda, com o time
begin
  if v_tel !~ '^\d{10,15}$' then
    raise exception 'telefone inválido' using errcode = '22023';
  end if;

  select * into v_conv from public.mari_conversas
   where telefone = v_tel and canal = p_canal and status in ('ativo', 'handoff_realizado')
   for update;

  -- 0155 (D2): quem saiu pelo fim da cadência (encerrado_ia) e volta a escrever reaproveita a mesma linha, no mesmo degrau.
  if not found then
    update public.mari_conversas m
       set status = 'ativo', etapa = 'retomada', cadencia_passo = 'nenhum', cadencia_proximo_em = null,
           ciclo_anterior = jsonb_strip_nulls(jsonb_build_object('motivo', m.handoff_motivo, 'em', m.handoff_em, 'encerrado_em', now(),
                              'origem', 'cliente voltou depois do fim da cadência', 'venda_id', m.venda_id)),
           ciclos_encerrados = coalesce(m.ciclos_encerrados, 0) + 1,
           handoff_motivo = null, handoff_em = null, handoff_briefing = null, chatwoot_resolvida = false, processando_ate = null,
           chatwoot_conversation_id = coalesce(v_cw, m.chatwoot_conversation_id)
     where m.id = (select x.id from public.mari_conversas x
                    where x.telefone = v_tel and x.canal = p_canal and x.status = 'encerrado_ia'
                    order by x.updated_at desc limit 1)
    returning * into v_conv;
    if found then
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (v_conv.id, 'sistema', '[cliente voltou depois do fim da cadência — a conversa segue de onde parou]', false);
    end if;
  end if;

  if not found then
    insert into public.mari_conversas (telefone, nome_contato, canal, origem, chatwoot_conversation_id)
    values (v_tel, nullif(btrim(p_nome), ''), p_canal,
            coalesce(v_orig, case when p_canal = 'teste' then 'teste' else 'direto' end),
            p_chatwoot_conversation_id)
    returning * into v_conv;
  elsif v_conv.origem = 'direto' and v_orig in ('meta_ads', 'instagram', 'facebook', 'site', 'fila_vero', 'indicacao') then
    -- 0033: conversa que já existia sem origem conhecida ganha a 1ª origem identificada (link (IG)/(FB) ou anúncio).
    update public.mari_conversas set origem = v_orig where id = v_conv.id returning * into v_conv;
  end if;

  if v_conv.status = 'handoff_realizado' and p_canal = 'whatsapp' and v_cw is not null
        and v_conv.chatwoot_conversation_id is distinct from v_cw then
    perform public._mari_fechar_ciclo(v_conv.id, 'nova conversa no Chatwoot (' || v_cw || ')');
    update public.mari_conversas set chatwoot_conversation_id = v_cw
     where id = v_conv.id returning * into v_conv;
  end if;
  -- 0259 (A4, conferência da sombra): também com a conversa ATIVA (ex.: Saída "pode voltar", que fica ativa) — o cliente escreveu
  -- numa conversa nova do Chatwoot e o NIOGEN seguia mandando etiquetas, notas, mensagens e "resolver" na antiga, já resolvida.
  if p_canal = 'whatsapp' and v_cw is not null and v_conv.chatwoot_conversation_id is distinct from v_cw then
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (v_conv.id, 'sistema', '[o cliente escreveu numa conversa nova do Chatwoot (' || v_cw || ', antes ' || coalesce(v_conv.chatwoot_conversation_id, '—')
            || ') — o NIOGEN passa a usar a nova]', false);
    update public.mari_conversas set chatwoot_conversation_id = v_cw, chatwoot_status = 'open', chatwoot_agente = null, chatwoot_time = null,
           chatwoot_etiquetas = '{}'
     where id = v_conv.id returning * into v_conv;
  end if;

  -- 0167 (Ricardo, 13/11; conversa #86): a Mari avisou "sem cobertura" e convidou o cliente a mandar o CEP ou o número certo.
  -- Se ele volta a escrever e ninguém do time assumiu, a conversa reabre na etapa do endereço para a Mari conferir de novo —
  -- até 3 voltas por conversa. dados.sem_cobertura_avisado guarda a hora do veredito: enquanto o endereço for o mesmo, a Mari
  -- sabe que já avisou e não repete; endereço novo zera o veredito (gatilho da 0133) e a consulta sai de novo.
  if v_conv.status = 'handoff_realizado' and v_conv.handoff_motivo = 'sem_cobertura' and v_conv.cobertura_decisao = 'sem_cobertura'
     and v_conv.cobertura_em is not null
     and not coalesce(v_conv.humano_atribuido, false) and v_conv.chatwoot_agente is null and not coalesce(v_conv.nao_contatar, false)
     and coalesce(case when v_conv.dados->>'sem_cobertura_voltas' ~ '^[0-9]+$' then (v_conv.dados->>'sem_cobertura_voltas')::int end, 0) < 3
     and not public._mari_optout(p_texto)
     and not exists (select 1 from public.mari_turnos t
                      where t.conversa_id = v_conv.id and t.papel = 'humano' and t.created_at > v_conv.handoff_em) then
    update public.mari_conversas m
       set status = 'ativo', etapa = 'endereco', handoff_motivo = null, handoff_em = null, handoff_briefing = null,
           chatwoot_resolvida = false,
           dados = coalesce(m.dados, '{}'::jsonb) || jsonb_build_object(
             'sem_cobertura_avisado', floor(extract(epoch from m.cobertura_em))::bigint,
             'sem_cobertura_voltas', coalesce(case when m.dados->>'sem_cobertura_voltas' ~ '^[0-9]+$' then (m.dados->>'sem_cobertura_voltas')::int end, 0) + 1)
     where m.id = v_conv.id
    returning * into v_conv;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (v_conv.id, 'sistema', '[cliente voltou a escrever depois do aviso de sem cobertura — a Mari confere o endereço de novo]', false);
  end if;

  -- 0189 (Ricardo, 13/11; conversa #39, Waldir): saiu por recusa (ou por sem contato), clicou no anúncio de novo e a Mari
  -- ficou muda. Recusa não é pedido de parar: quem volta a escrever reabre na retomada, com a Mari. Não reabre se alguém do
  -- time é o dono, se o time falou nas últimas 12 h, se o cliente pediu para parar, nem na despedida logo depois da saída.
  if v_conv.status = 'handoff_realizado' and v_conv.handoff_motivo in ('recusa_compra', 'sem_contato')
     and not coalesce(v_conv.humano_atribuido, false) and v_conv.chatwoot_agente is null and not coalesce(v_conv.nao_contatar, false)
     and not public._mari_optout(p_texto)
     and coalesce(v_conv.handoff_em, '-infinity') < now() - interval '30 minutes'
     and not exists (select 1 from public.mari_turnos t
                      where t.conversa_id = v_conv.id and t.papel = 'humano' and t.created_at > now() - interval '12 hours') then
    perform public._mari_fechar_ciclo(v_conv.id, 'cliente voltou a escrever depois da saída');
    update public.mari_conversas set chatwoot_resolvida = false where id = v_conv.id returning * into v_conv;
  end if;

  -- 0265 (passo 5): a volta do cliente em Saída passa pela porta. "Pode voltar" (recusou, sem resposta…) e escreveu de verdade
  -- (não só "ok, obrigado") mais de 30 min depois da Saída → reabre onde parou, com a Mari. Definitiva, Não contatar e cliente
  -- Nio não reabrem (a tabela diz). Era o ramo "cliente voltou a escrever" do _funil_antes, que saiu.
  if coalesce(v_conv.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada', 'teste_duplicada')
     and not coalesce(v_conv.nao_contatar, false) and not public._mari_optout(p_texto)
     and (p_midia is not null or not public._saida_so_confirmacao(p_texto))
     and coalesce(v_conv.saida_em, v_conv.funil_destino_em, '-infinity') < now() - interval '30 minutes'   -- 0189: despedida não reabre
     and public._porta_situacao(v_conv.id, null::uuid) = 'saida_pode_voltar' then
    perform public.porta('cliente_escreveu', v_conv.id, null::uuid, jsonb_build_object('acao', 'reabrir'));
    select * into v_conv from public.mari_conversas where id = v_conv.id;
  end if;

  -- 0261 (Ricardo, 17/11: "Cliente já é Nio, em qualquer situação, educadamente a Mari encerra a conversa, pedindo para procurar os
  -- canais oficiais. Se depois de alguns minutos o cliente insistir, silencie a conversa. Somos uma revenda da Nio"): conversa em
  -- "já é cliente Nio" em que já houve a despedida (a própria Mari deu a Saída, ou falamos depois dela) e o cliente escreve de novo → silenciada.
  if coalesce(v_conv.funil_destino, '') = 'ja_cliente_nio' and coalesce(v_conv.quadro_encerrada_motivo, '') <> 'suporte_nio'
     and (v_conv.handoff_motivo = 'ja_cliente_nio' or v_conv.ciclo_anterior ->> 'motivo' = 'ja_cliente_nio'   -- a Mari se despediu ao dar a Saída
          or exists (select 1 from public.mari_turnos t where t.conversa_id = v_conv.id and t.papel in ('mari', 'humano')
                      and t.created_at > coalesce(v_conv.funil_destino_em, v_conv.handoff_em, v_conv.created_at))) then
    -- 0265: o silêncio é da porta (cliente_escreveu em "Cliente Nio")
    perform public.porta('cliente_escreveu', v_conv.id, null::uuid, jsonb_build_object('acao', 'silenciar'));
    select * into v_conv from public.mari_conversas where id = v_conv.id;
  end if;
  -- 0261: silenciada (cliente Nio) = a Mari não responde, e o time também não (situação 15: ninguém)
  v_sil := coalesce(v_conv.quadro_encerrada_motivo, '') = 'suporte_nio';

  v_pos := public._mari_pos_handoff(v_conv);

  -- 0250 (H2): Não contatar gravado no NIOGEN cala a Mari, mesmo que tirem a etiqueta à mão no Chatwoot
  v_opt  := public._mari_optout(p_texto) or coalesce(v_conv.nao_contatar, false);
  v_posv := coalesce(v_conv.funil_destino, '') = 'instalada';

  insert into public.mari_turnos (conversa_id, papel, texto, pendente, midia)
  values (v_conv.id, 'lead', coalesce(p_texto, ''), (v_conv.status = 'ativo' or v_pos) and not v_opt and not v_posv and not v_sil, public._midia_ok(p_midia));

  update public.mari_conversas
     set ultima_entrada_ts = v_ts,
         ultima_msg_lead_at = now(),
         nome_contato = coalesce(nome_contato, nullif(btrim(p_nome), '')),
         -- 0155: a trava "resolvida" da cadência cai quando o cliente escreve e a conversa segue em andamento
         chatwoot_resolvida = case when coalesce(funil_destino, 'em_andamento') = 'em_andamento' then false else chatwoot_resolvida end
   where id = v_conv.id;

  if v_opt and not coalesce(v_conv.nao_contatar, false) then perform public.conversa_nao_contatar(v_conv.id, 'cliente escreveu: ' || left(btrim(coalesce(p_texto, '')), 40)); end if;
  if v_posv and not v_opt then perform public._mari_pos_venda(v_conv.id); end if;

  return jsonb_build_object(
    'conversa_id', v_conv.id,
    'ts', v_ts,
    'status', v_conv.status,
    'silencio', (v_conv.status <> 'ativo' and not v_pos) or v_opt or v_posv or v_sil,
    'optout', v_opt, 'pos_venda', v_posv,   -- em handoff: humano conduz, Mari calada (salvo a janela 0061)
    'pos_handoff', v_pos,
    'nova', v_conv.created_at >= now() - interval '1 second');
end;
$function$;

commit;
