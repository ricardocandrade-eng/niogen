-- NIOGEN | supabase/migrations/0255_reabrir_titular_pedido_nosso.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Portão dos fluxos, lote 3 do mapa (Ricardo, 17/11: "Pode fechar o lote 3"). Três defeitos achados pelos cenários:
--   H8  lead_reabrir: reabrir um lead em Saída fazia a cadência mandar NA HORA o toque atrasado (D7), contado do silêncio antigo.
--       Agora a escada recomeça do momento da reabertura (cadencia_retorno_em = now(), a mesma base que o retorno já usa).
--   B12 mari_dup_gravar: "pedido em andamento" no portal só era reconhecido como nosso com crédito rodado pela extensão/consulta
--       (operador_consultas) ou pedido/OS gravados. Crédito gravado pelo time no botão da ficha não contava → o lead virava
--       "já é cliente Nio" (Saída). Agora conta também a venda viva com crédito aprovado (ou só cartão).
--   B10 venda_trocar_titular: titular novo com crédito aprovado não fechava a pendência "outro CPF" → a cadência ficava pausada e
--       a Live cobrava. Agora ela fecha como "destravou", com o mesmo evento que pendencia_encerrar grava.
-- Funções recriadas a partir das que estão no ar (cópia conferida). Regra 20: nenhum estado novo. Cenários: H8, B12, B10 + o portão.
begin;

CREATE OR REPLACE FUNCTION public.lead_reabrir(p_conversa uuid, p_venda uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
           nao_contatar = false, chatwoot_resolvida = false,
           cadencia_retorno_em = now()   -- 0255 (H8): a escada da Mari recomeça de agora — sem toque atrasado na hora de reabrir
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
$function$;

CREATE OR REPLACE FUNCTION public.mari_dup_gravar(p_conversa uuid, p_saida jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
                    where mc.id = p_conversa and (nullif(btrim(vv.nio_pedido), '') is not null or nullif(btrim(vv.nio_os), '') is not null
                           -- 0255 (B12): crédito gravado pelo time na ficha (botão Crédito) também mostra que o pedido é nosso
                           or (vv.status <> 'saida' and vv.credito_resultado in ('aprovado', 'so_cartao'))))
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
end $function$;

CREATE OR REPLACE FUNCTION public.venda_trocar_titular(p_venda uuid, p_nome text, p_cpf text, p_relacao text, p_motivo text DEFAULT NULL::text, p_credito text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v    public.vendas;
  doc  text := public._so_digitos(p_cpf);
  nome text := upper(btrim(regexp_replace(coalesce(p_nome, ''), '\s+', ' ', 'g')));
  rel  text := btrim(coalesce(p_relacao, ''));
  soltas int := 0;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice troca o titular.' using errcode = '42501';
  end if;
  if not public._cpf_ok(doc) then raise exception 'CPF do novo titular inválido (confira os dígitos).' using errcode = 'P0001'; end if;
  if length(nome) < 5 or nome !~ ' ' then raise exception 'Nome completo do novo titular (como saiu na Receita).' using errcode = 'P0001'; end if;
  if length(rel) < 2 then raise exception 'Diga o parentesco do titular com quem conversa (pai, mãe, filho, cônjuge…).' using errcode = 'P0001'; end if;
  if p_credito is not null and p_credito not in ('aprovado', 'so_cartao', 'pendente', 'negado') then
    raise exception 'Resultado de crédito inválido.' using errcode = 'P0001';
  end if;
  select * into v from public.vendas where id = p_venda for update;
  if not found then raise exception 'Venda não encontrada.' using errcode = 'P0001'; end if;
  if v.status = 'saida' then raise exception 'A venda está em Saída: reabra pela ficha.' using errcode = 'P0001'; end if;
  if public._so_digitos(v.cliente_cpf_cnpj) = doc then raise exception 'Esse já é o CPF do titular desta venda.' using errcode = 'P0001'; end if;

  update public.vendas set
    titular_anterior = jsonb_build_object('nome', v.cliente_nome, 'cpf_cnpj', v.cliente_cpf_cnpj, 'credito', v.credito_resultado,
                                          'credito_em', v.credito_em, 'ate', now()),
    contato_nome = coalesce(contato_nome, v.cliente_nome),
    contato_relacao = rel,
    cliente_nome = nome,
    cliente_cpf_cnpj = doc,
    credito_resultado = p_credito,
    credito_em = case when p_credito is null then null else now() end,
    titular_trocado_em = now(),
    titular_trocado_por = auth.uid()
  where id = v.id;

  -- As biometrias do CPF antigo deixam de valer para esta venda (o próximo GED360 casa as do titular novo pelo CPF).
  update public.nio_biometria set venda_id = null where venda_id = v.id and cpf_cnpj is distinct from doc;
  get diagnostics soltas = row_count;

  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (v.id, 'titular_trocado', jsonb_build_object('de', v.cliente_nome, 'para', nome, 'relacao', rel,
          'motivo', nullif(btrim(coalesce(p_motivo, '')), ''), 'credito', p_credito, 'biometrias_soltas', soltas), auth.uid());

  -- Casa já as biometrias do titular novo que o GED360 leu antes da troca (o mapa aplica na próxima leitura).
  update public.nio_biometria set venda_id = v.id, ultima_leitura = now()
   where venda_id is null and cpf_cnpj = doc and data_envio > now() - interval '15 days';

  -- 0255 (B10): titular novo com crédito aprovado → a pendência "outro CPF" destravou (antes ficava aberta: cadência pausada e cobrança na Live)
  if p_credito in ('aprovado', 'so_cartao') then
    with f as (
      update public.venda_pendencias
         set encerrada_em = now(), encerrada_por = auth.uid(), resultado = 'destravou',
             nota_encerramento = 'titular trocado para ' || nome || ' com crédito ' || p_credito
       where venda_id = v.id and motivo = 'credito_outro_cpf' and encerrada_em is null
      returning id, aberta_em)
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    select v.id, 'pendencia', jsonb_build_object('acao', 'encerrada', 'pendencia_id', f.id, 'motivo', 'credito_outro_cpf',
           'resultado', 'destravou', 'nota', 'titular novo com crédito ' || p_credito,
           'dias', ((now() at time zone 'America/Sao_Paulo')::date - (f.aberta_em at time zone 'America/Sao_Paulo')::date)), auth.uid()
      from f;
  end if;

  return jsonb_build_object('ok', true, 'titular', nome, 'contato', coalesce(v.contato_nome, v.cliente_nome), 'relacao', rel);
end;
$function$;

commit;
