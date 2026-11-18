-- NIOGEN | supabase/migrations/0290_porta_mari_handoff_cadencia.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 18/11: "Feche também o handoff e a cadência da Mari pela porta".
-- Até aqui a Saída dada pela Mari saía do gatilho _funil_antes (ramos "hand" e "cad"): quando a Mari passava adiante com motivo de
-- Saída (fora_de_area, sem_cobertura, recusa_compra, ja_cliente_nio, sem_contato) ou a cadência acabava (ENCERRAR, 48 h depois do D15),
-- o gatilho calculava o destino. Agora:
--  (1) _porta_mari_destino(conversa, origem): peça da porta com a mesma conta (motivo da Mari → destino; a Saída dura vence pela ordem do
--      config_funil), grava com porta.aplicando, projeta no Chatwoot e anota na sombra (funil:<destino>, origem mari_handoff/mari_cadencia).
--  (2) mari_handoff__nucleo (logo depois de gravar o handoff) e mari_cadencia_registrar (no ENCERRAR) chamam a peça.
--  (3) _funil_antes perde os ramos hand/cad: fica só com a etapa, a Saída dura, o 0151 (sem cobertura revisto) e a 1ª conta.
-- Mesmo destino, mesma nota, mesmo Chatwoot de antes. Handoff que não é Saída (dados completos, pediu humano, objeção, interesse caindo…)
-- não muda o destino, como antes.
-- Regra 20: (1)–(2) nada novo; (3) a Saída da Mari agora tem função da porta e autor (origem); (4) sem mudança; (5) cenário X27 + R10.
-- Tela, guia do backoffice e desempenho: sem impacto. Funções recriadas da versão no ar (18/11 ~14h45).
begin;

create or replace function public._porta_mari_destino(p_conversa uuid, p_origem text)
returns text language plpgsql security definer set search_path to 'public' as $function$
declare
  c        public.mari_conversas;
  d        jsonb;
  alvo     text; det text; antes text; ant_dest text;
begin
  select * into c from public.mari_conversas where id = p_conversa;
  if not found then return null; end if;
  d := public._funil_calcular(c);
  -- a mesma fonte que o _funil_antes usava: o handoff da Mari antes do fim da cadência
  if d ->> 'hand' is not null then alvo := d ->> 'hand'; det := d ->> 'hand_det';
  elsif d ->> 'cad' is not null then alvo := d ->> 'cad'; det := d ->> 'cad_det';
  else return null; end if;
  if d ->> 'duro' is not null and public._funil_ordem('destino', d ->> 'duro') <= public._funil_ordem('destino', alvo) then
    alvo := d ->> 'duro'; det := d ->> 'duro_det';
  end if;
  ant_dest := coalesce(c.funil_destino, 'em_andamento');
  if alvo = ant_dest then return alvo; end if;
  antes := public._porta_situacao(c.id, null::uuid);

  perform set_config('porta.aplicando', '1', true);
  update public.mari_conversas
     set funil_evento = null, funil_destino = alvo, funil_detalhe = det, funil_destino_em = now(),
         funil_alerta = null, funil_alerta_em = null
   where id = c.id;
  perform set_config('porta.aplicando', '', true);

  perform public._porta_projetar(c.id, 'destino');
  perform public._porta_anotar('funil:' || alvo, p_origem, c.id, c.venda_id, antes,
    jsonb_build_object('ok', true, 'resumo', ant_dest || ' → ' || alvo || coalesce(' (' || det || ')', '')));
  return alvo;
exception when others then
  perform set_config('porta.aplicando', '', true);
  insert into public.mari_erros (conversa_id, no_n8n, mensagem) values (p_conversa, '_porta_mari_destino', sqlerrm);
  return null;
end $function$;
revoke execute on function public._porta_mari_destino(uuid, text) from public, anon, authenticated;

-- (2) a Mari passa adiante
CREATE OR REPLACE FUNCTION public.mari_handoff__nucleo(p_conversa uuid, p_motivo text, p_lead jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  c        public.mari_conversas;
  l        jsonb := coalesce(p_lead, '{}'::jsonb);
  d        jsonb;
  v_plano  public.config_planos;
  v_venda  uuid;
  v_motivo text;
  v_seg    text;
  v_forma  text;
  v_orig   text;
  v_cpf    text;
  v_tel    text;
  v_cluster text;
  v_dfv    jsonb;
  v_brief  text;
  v_obs    text;
  v_inst   text;
  v_viab   text;
  v_vnota  text;
  v_prox   text;
  v_endp   text;
  v_exist  uuid;   -- 0030: venda que já existe (duplicidade) — o link vai na nota do Chatwoot
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('ok', false, 'motivo_recusa', 'conversa inexistente'); end if;

  -- Guard-rail 10: não repetir handoff.
  if c.status <> 'ativo' then
    return jsonb_build_object('ok', true, 'repetido', true, 'venda_id', c.venda_id);
  end if;

  -- 0266 (C3, Ricardo 17/11): "interesse caindo" e "múltiplos decisores" não passam para o time — a conversa fica com a Mari
  -- (status ativo; a Mari segue respondendo). O 🔥 na Live fica para o debate da Live.
  if p_motivo in ('interesse_caindo', 'multiplos_decisores') then
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[a Mari sinalizou ' || case p_motivo when 'interesse_caindo' then 'interesse caindo' else 'múltiplos decisores' end
            || ' — a conversa fica com ela (C3)]', false);
    return jsonb_build_object('ok', true, 'fica_com_mari', true, 'venda_id', c.venda_id);
  end if;

  d := c.dados || coalesce(l -> 'dados', '{}'::jsonb);
  v_inst := coalesce(nullif(btrim(c.instalacao_preferencia), ''), nullif(btrim(l ->> 'instalacao_preferencia'), ''));
  v_viab := coalesce(c.nio_viab_resultado, nullif(l ->> 'nio_viab_resultado', ''));
  if v_viab not in ('viavel', 'sem_viabilidade', 'nao_encontrado', 'posse', 'indisponivel') then v_viab := null; end if;
  v_endp := coalesce(nullif(btrim(c.nio_viab_endereco_portal), ''), nullif(btrim(l ->> 'nio_viab_endereco_portal'), ''));

  -- Nota da viabilidade oficial (nunca nega venda): viável = atendido; o resto = conferir à mão antes do pedido.
  v_vnota := case
    when v_viab = 'viavel' then 'portal: viável' || coalesce(' · até ' || coalesce(c.nio_viab_velocidade, l ->> 'nio_viab_velocidade'), '')
    when v_viab = 'posse' then 'portal: posse (endereço com Nio ativo) — cliente disse que não tem; conferir manualmente antes de abrir o pedido'
    when v_viab is not null then 'portal: ' || v_viab || ' — conferir manualmente (variações de CEP/rua/número) antes de abrir o pedido'
    else 'portal: não consultado — conferir manualmente (variações de CEP/rua/número) antes de abrir o pedido' end
    || coalesce(' · endereço como a Nio cadastrou: ' || v_endp, '');

  -- Próximo passo do humano (venda remota, 05/11; 0032: o link da biometria é da Nio): sempre o mesmo texto.
  v_prox := case when p_motivo = 'dados_completos' then
    'Próximo passo: abrir pedido no portal PAP'
    || case when coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id') is not null
            then ' (interesse ' || coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id') || ' já criado na viabilidade)' else '' end
    || ' e registrar o nº do pedido no NIOGEN → a Nio dispara o link da biometria (WhatsApp + e-mail) → avisar o cliente nesta conversa → agendar a instalação ('
    || coalesce(v_inst, 'preferência não informada') || ').' end;

  update public.mari_conversas set
    status = 'handoff_realizado', etapa = 'handoff', handoff_motivo = p_motivo, handoff_em = now(),
    handoff_briefing = concat_ws(E'\n', coalesce(nullif(btrim(l ->> 'briefing'), ''), handoff_briefing),
                                 case when p_motivo = 'dados_completos' or v_viab is not null then v_vnota end, v_prox),
    dados = d, processando_ate = null,
    instalacao_preferencia = coalesce(v_inst, instalacao_preferencia),
    -- 0189: recusa não é pedido de parar — o "não contatar" fica só para quem pediu (SAIR, PARAR, botão do time)
    agendamento_retorno = coalesce((l ->> 'agendamento_retorno')::timestamptz, agendamento_retorno)
  where id = p_conversa
  returning * into c;
  -- 0290: motivo de Saída (fora de área, sem cobertura, recusou, já cliente Nio, sem contato) → a Saída é da porta
  perform public._porta_mari_destino(p_conversa, 'mari_handoff');
  select * into c from public.mari_conversas where id = p_conversa;

  if p_motivo <> 'dados_completos' then
    return jsonb_build_object('ok', true, 'venda_id', null);
  end if;

  -- Pré-condições da venda (ordem: elegibilidade, área, plano, dados mínimos, duplicidade). Viabilidade NÃO entra.
  v_cluster := public.cluster_da_area(c.cidade, c.uf, c.endereco_cep ->> 'bairro');
  v_cpf := regexp_replace(coalesce(d ->> 'cpf', ''), '\D', '', 'g');
  v_tel := regexp_replace(coalesce(d ->> 'telefone', c.telefone), '\D', '', 'g');
  select * into v_plano from public.config_planos where codigo = c.plano_escolhido;

  -- 0030: a mesma regra de duplicidade de sempre, agora guardando QUAL venda já existe (a mais recente).
  select v.id into v_exist from public.vendas v
   where v.status <> 'saida'
     and ((v_cpf <> '' and regexp_replace(coalesce(v.cliente_cpf_cnpj, ''), '\D', '', 'g') = v_cpf)
       or (regexp_replace(coalesce(v.cep, ''), '\D', '', 'g') = c.cep
           and lower(btrim(coalesce(v.numero, ''))) = lower(btrim(c.numero))
           and lower(btrim(coalesce(v.complemento, ''))) = lower(btrim(coalesce(c.complemento, '')))))
   order by v.criado_em desc
   limit 1;

  v_motivo := case
    when coalesce(c.elegibilidade, '') <> 'ok' then 'elegibilidade não confirmada (' || coalesce(c.elegibilidade, 'vazia') || ')'
    when v_cluster is null then 'fora da área de atuação (' || coalesce(c.cidade, 'cidade desconhecida') || ')'
    when v_plano.id is null then 'plano não escolhido'
    when coalesce(btrim(d ->> 'nome'), '') = '' then 'nome do cliente ausente'
    when c.cep is null or c.numero is null then 'endereço incompleto'
    when v_exist is not null
      then 'duplicidade: CPF ou endereço já tem venda ativa no NIOGEN'
  end;

  if v_motivo is null then
    v_seg := case when c.segmento = 'empresas' then case when c.mei then 'MEI' else 'NMEI' end else 'PF' end;
    v_forma := coalesce(c.forma_pagamento, l ->> 'forma_pagamento');
    v_forma := case v_forma when 'debito' then 'dacc' when 'debito_automatico' then 'dacc' else v_forma end;
    if v_forma not in ('boleto', 'cartao', 'dacc') then v_forma := null; end if;
    v_orig := case when c.origem in ('meta_ads', 'instagram', 'facebook', 'site', 'fila_vero', 'indicacao') then c.origem else 'outro' end;
    v_dfv := c.dfv_detalhe;

    v_brief := coalesce(l ->> 'briefing', '');
    v_obs := concat_ws(E'\n',
      'Mari (' || c.canal || ') — handoff dados_completos em ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
      'Plano: ' || v_plano.nome || ' · forma: ' || coalesce(v_forma, '?'),
      'Instalação: preferência ' || coalesce(v_inst, '?') || ' (data o nosso time confirma)',
      'Viabilidade Nio — ' || v_vnota,
      'DFV: ' || case coalesce(c.dfv_resultado, '')
                   when 'viavel' then 'viável'
                   when 'viavel_predio' then 'viável (prédio) — conferir unidade'
                   when 'endereco_ocupado' then 'indica Nio ativo no endereço — confirmar com o cliente e no portal antes de abrir o pedido'
                   else 'conferir manualmente antes de abrir o pedido' end,
      nullif(v_brief, ''),
      v_prox);

    begin
      insert into public.vendas (
        status, origem, origem_ref, cliente_nome, cliente_cpf_cnpj, cliente_whatsapp, cliente_email, segmento,
        cep, logradouro, numero, complemento, bairro, cidade, uf, plano_id, forma_pagamento,
        trava_area, trava_cpf_valido, trava_contato_confirmado, observacoes,
        dfv_viabilidade, dfv_resultado, dfv_hp_livre, dfv_hcs, dfv_faixa_credito, dfv_classificacao,
        dfv_particao, dfv_origem, dfv_consultado_em,
        instalacao_preferencia, biometria_status,
        nio_viab_resultado, nio_viab_velocidade, nio_viab_interesse_id, nio_viab_em, nio_viab_origem, nio_viab_endereco_portal)
      values (
        '0_qualificado', v_orig, 'mari:' || c.id, btrim(d ->> 'nome'), nullif(v_cpf, ''), v_tel, nullif(btrim(d ->> 'email'), ''), v_seg,
        c.cep, c.endereco_cep ->> 'logradouro', c.numero, c.complemento,
        coalesce(c.endereco_cep ->> 'bairro', v_dfv ->> 'bairro'), c.cidade, c.uf, v_plano.id, v_forma,
        true, case when v_cpf <> '' then public.mari_cpf_valido(v_cpf) end,
        case when coalesce((d ->> 'telefone_confirmado')::boolean, false) or v_tel <> '' then true end, v_obs,
        case c.dfv_resultado
          when 'viavel' then 'viavel' when 'viavel_predio' then 'viavel_predio'
          when 'endereco_ocupado' then 'sem_viabilidade' when 'sem_porta_livre' then 'sem_viabilidade'
          when 'nao_encontrado' then 'nao_encontrado'
          else 'nao_consultado' end,
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then c.dfv_resultado end,
        (v_dfv ->> 'hp_livre')::int, (v_dfv ->> 'hc_tot')::int,
        public.dfv_faixa_codigo(v_dfv ->> 'faixa_credito'),
        case when v_dfv ->> 'classificacao' in ('ALTO', 'MEDIO', 'BAIXO') then v_dfv ->> 'classificacao' end,
        (v_dfv ->> 'particao')::date,
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then 'auto' end,
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then now() end,
        v_inst, 'nao_enviada',
        v_viab, coalesce(c.nio_viab_velocidade, l ->> 'nio_viab_velocidade'),
        coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id'),
        case when v_viab is not null then coalesce(c.nio_viab_em, now()) end,
        case when v_viab is not null then 'mari' end,
        v_endp)
      returning id into v_venda;

      insert into public.eventos_venda (venda_id, tipo, detalhe)
      values (v_venda, 'mari_handoff', jsonb_strip_nulls(jsonb_build_object(
        'conversa_id', c.id, 'motivo', p_motivo, 'canal', c.canal, 'briefing', nullif(v_brief, ''),
        'instalacao_preferencia', v_inst, 'nio_viab_resultado', v_viab, 'dfv_resultado', c.dfv_resultado)));

      update public.mari_conversas set venda_id = v_venda where id = p_conversa;
    exception when others then
      v_motivo := sqlerrm;
    end;
  end if;

  if v_motivo is not null then
    insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
    values (p_conversa, 'mari_handoff', 'venda não criada: ' || v_motivo,
            jsonb_strip_nulls(jsonb_build_object('lead', l, 'dados', d, 'venda_existente_id', case when v_motivo like 'duplicidade%' then v_exist end)));
    return jsonb_build_object('ok', false, 'venda_id', null, 'motivo_recusa', v_motivo,
                              'venda_existente_id', case when v_motivo like 'duplicidade%' then v_exist end);
  end if;

  return jsonb_build_object('ok', true, 'venda_id', v_venda);
end;
$function$;

-- (2) fim da cadência
CREATE OR REPLACE FUNCTION public.mari_cadencia_registrar(p_conversa uuid, p_passo text, p_ok boolean, p_erro text DEFAULT NULL::text, p_agora timestamp with time zone DEFAULT now(), p_texto text DEFAULT NULL::text, p_excecao text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  c public.mari_conversas;
  v_bio timestamptz;
  v_inst timestamptz;
  v_prox record;
  v_eco int := 0;
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('ok', false, 'erro', 'conversa inexistente'); end if;

  if not coalesce(p_ok, false) then
    insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
    values (p_conversa, 'mari_cadencia', 'envio da cadência falhou (' || coalesce(p_passo, '?') || '): ' || coalesce(p_erro, 'sem detalhe'),
            jsonb_build_object('passo', p_passo, 'agora', p_agora));
    return jsonb_build_object('ok', true, 'registrado', 'erro');
  end if;

  if p_passo = 'ENCERRAR' then
    update public.mari_conversas set status = 'encerrado_ia', handoff_motivo = 'sem_contato',
           cadencia_passo = 'encerrada', cadencia_passo_em = p_agora, cadencia_proximo_em = null
     where id = p_conversa;
    insert into public.mari_turnos (conversa_id, papel, texto, tags, created_at)
    values (p_conversa, 'sistema', 'Saída "Sem contato": 48 h sem resposta depois do D15.',
            jsonb_build_object('cadencia', 'ENCERRAR'), p_agora);
    perform public._porta_mari_destino(p_conversa, 'mari_cadencia');   -- 0290: a Saída "Sem contato" é da porta
    return jsonb_build_object('ok', true, 'registrado', 'encerrada');
  end if;
  if p_passo = 'BIO3' then
    return jsonb_build_object('ok', false, 'erro', 'BIO3 é ligação do nosso time: nunca registrada como envio automático');
  end if;

  insert into public.mari_turnos (conversa_id, papel, texto, tags, created_at)
  values (p_conversa, 'mari', coalesce(p_texto, ''),
          jsonb_strip_nulls(jsonb_build_object('cadencia', p_passo, 'excecao', p_excecao, 'simulado', c.canal = 'teste')), p_agora);

  -- 0052: eco do próprio envio que chegou ao mari_principal ANTES deste registro (virou turno 'humano' falso).
  if c.canal = 'whatsapp' and coalesce(btrim(p_texto), '') <> '' then
    delete from public.mari_turnos t
     where t.conversa_id = p_conversa and t.papel = 'humano'
       and btrim(t.texto) = btrim(p_texto)
       and t.created_at >= p_agora - interval '1 minute'
       and t.created_at <= greatest(now(), p_agora) + interval '5 minutes';
    get diagnostics v_eco = row_count;
  end if;

  insert into public.contatos_cliente (venda_id, conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
  values (c.venda_id, c.id, c.telefone, 'whatsapp', 'saida', 'mari', p_agora, p_passo, 'ativo',
          'cadência ' || p_passo || coalesce(' · ' || p_excecao, '') || case when c.canal = 'teste' then ' (simulado)' else '' end);

  if p_passo = 'RETORNO' then
    update public.mari_conversas set cadencia_retorno_em = p_agora,
           cadencia_passo = case when cadencia_passo in ('nenhum', 'L15', 'F1', 'F2', 'F3', 'F4', 'P1') then 'F5' else cadencia_passo end,
           cadencia_passo_em = p_agora
     where id = p_conversa;
  elsif p_passo = 'VISITA' then   -- histórico (0018); não é mais gerado
    select biometria_em into v_bio from public.vendas where id = c.venda_id;
    update public.mari_conversas set visita_confirmada_para = v_bio where id = p_conversa;
  elsif p_passo = 'BIO1' then
    update public.mari_conversas set bio_lembrete_em = p_agora where id = p_conversa;
  elsif p_passo = 'BIOVOLTA' then   -- 0196
    update public.mari_conversas set bio_volta_em = p_agora where id = p_conversa;
  elsif p_passo = 'CARTAO' then   -- 0191
    update public.mari_conversas set cartao_avisado_em = p_agora where id = p_conversa;
  elsif p_passo = 'CARTAO2' then
    update public.mari_conversas set cartao_lembrete_em = p_agora where id = p_conversa;
  elsif p_passo = 'INSTALACAO' then
    select instalacao_agendada_para into v_inst from public.vendas where id = c.venda_id;
    update public.mari_conversas set instalacao_avisada_para = v_inst, instalacao_avisada_em = p_agora where id = p_conversa;
  elsif p_passo = 'VESPERA' then
    select instalacao_agendada_para into v_inst from public.vendas where id = c.venda_id;
    update public.mari_conversas set instalacao_lembrada_para = v_inst where id = p_conversa;
  elsif p_passo = 'L15' then   -- 0070: lembrete da abertura B2 — passo + horário em dados (medição v_mari_abertura)
    update public.mari_conversas set cadencia_passo = p_passo, cadencia_passo_em = p_agora,
           dados = dados || jsonb_build_object('abertura_lembrete_em', p_agora)
     where id = p_conversa;
  else
    update public.mari_conversas set cadencia_passo = p_passo, cadencia_passo_em = p_agora where id = p_conversa;
  end if;

  select a.proximo_passo, a.proximo_em into v_prox
    from public.mari_cadencia_avaliar(p_agora + interval '1 second', p_conversa) a limit 1;
  update public.mari_conversas set cadencia_proximo_em = v_prox.proximo_em where id = p_conversa;

  return jsonb_build_object('ok', true, 'registrado', p_passo, 'proximo_passo', v_prox.proximo_passo,
                            'proximo_em', v_prox.proximo_em, 'eco_removido', v_eco);
end;
$function$;

-- (3) o gatilho do funil sem os ramos da Mari
CREATE OR REPLACE FUNCTION public._funil_antes()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d        jsonb;
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
  -- 0289: venda, reabrir e Quadro saíram daqui — a venda mudada por fora é da porta (_porta_venda_mudou, 0288) e o Quadro/abertura
  -- gravam pela porta; aqui ficam a Mari (handoff), a cadência e a Saída dura
  -- 0290: handoff e fim da cadência da Mari também saíram daqui — dão a Saída pela porta (_porta_mari_destino). Ficam a Saída dura,
  -- o 0151 e a 1ª conta.
  if d ->> 'duro' is not null then
    novo := d ->> 'duro'; det := d ->> 'duro_det';
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

commit;
