-- NIOGEN | supabase/migrations/0030_mari_retomada_venda_nao_criada.sql | 05/11/2026 — Claude Code (prompt nº 18)
-- Rodada final antes da Mari entrar em produção (06/11). Número 0030 porque a 0029 está reservada para o prompt 17
-- (nio_ciclos_calendario) — quando ela vier, o push precisa de `--include-all`.
--
-- A) RETOMAR A CONVERSA DEPOIS DE RESOLVIDA (teste real de 05/11, conversa Chatwoot 1): depois do handoff a conversa
--    ficava em status 'handoff_realizado' para sempre; resolvida e reaberta pelo cliente, sem dono nem time, o
--    mari_entrada continuava devolvendo silencio (execuções 450541 e 450553). Agora:
--    · Chatwoot `conversation_status_changed` → resolved (webhook 21048, já assinado) chama mari_encerrar_ciclo:
--      o ciclo da Mari fecha (o handoff vai para ciclo_anterior, histórico e dados ficam), status volta a 'ativo'.
--      Reaberta sem dono → a Mari responde sabendo o histórico. Com dono, time ou `nao-contatar` → o guard 2h cala.
--    · Rede de segurança no mari_entrada: mensagem que chega por OUTRA conversa do Chatwoot (o Chatwoot abriu uma nova
--      para o mesmo contato) também fecha o ciclo antigo — a conversa antiga só existe porque foi resolvida.
--    · chatwoot_resolvida = true no fechamento: a cadência (desligada) já trata "resolvida" como parada; assim uma
--      conversa com venda que volta para a Mari nunca entra na escada de lead.
-- B) VENDA NÃO CRIADA: mari_handoff devolve venda_existente_id na duplicidade, para a nota privada do Chatwoot levar o
--    link da ficha que já existe (o backoffice decide). A regra da duplicidade não mudou.

alter table public.mari_conversas
  add column if not exists ciclos_encerrados int not null default 0,
  add column if not exists ciclo_anterior jsonb;
comment on column public.mari_conversas.ciclo_anterior is
  'Último handoff encerrado (conversa resolvida no Chatwoot): motivo, em, encerrado_em, origem, venda_id, briefing. 0030.';

-- Fecha o ciclo da Mari numa conversa em handoff: guarda o handoff em ciclo_anterior e volta para 'ativo'.
create or replace function public._mari_fechar_ciclo(p_conversa uuid, p_origem text)
returns jsonb language plpgsql set search_path = public as $$
declare
  c public.mari_conversas;
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found or c.status <> 'handoff_realizado' then
    return jsonb_build_object('ok', true, 'fechado', false, 'status', c.status);
  end if;
  update public.mari_conversas set
    status = 'ativo',
    etapa = 'retomada',
    ciclo_anterior = jsonb_strip_nulls(jsonb_build_object(
      'motivo', c.handoff_motivo, 'em', c.handoff_em, 'encerrado_em', now(), 'origem', p_origem,
      'venda_id', c.venda_id, 'briefing', c.handoff_briefing)),
    ciclos_encerrados = c.ciclos_encerrados + 1,
    handoff_motivo = null, handoff_em = null, handoff_briefing = null,
    chatwoot_resolvida = true,
    processando_ate = null
  where id = p_conversa;
  -- Marca no histórico (papel 'sistema' não vai para o modelo nem para o Chatwoot).
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (p_conversa, 'sistema', '[ciclo da Mari encerrado — ' || p_origem || '; handoff anterior: '
          || coalesce(c.handoff_motivo, '?') || ']', false);
  return jsonb_build_object('ok', true, 'fechado', true, 'conversa_id', p_conversa, 'motivo_anterior', c.handoff_motivo,
                            'venda_id', c.venda_id);
end;
$$;
revoke execute on function public._mari_fechar_ciclo(uuid, text) from public, anon, authenticated;
grant execute on function public._mari_fechar_ciclo(uuid, text) to service_role;

-- Chamado pelo n8n no evento conversation_status_changed → resolved do Chatwoot.
create or replace function public.mari_encerrar_ciclo(p_chatwoot_conversation_id text)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_id uuid;
begin
  if coalesce(btrim(p_chatwoot_conversation_id), '') = '' then
    return jsonb_build_object('ok', false, 'erro', 'conversa do Chatwoot vazia');
  end if;
  select id into v_id from public.mari_conversas
   where canal = 'whatsapp' and chatwoot_conversation_id = btrim(p_chatwoot_conversation_id)
     and status = 'handoff_realizado'
   order by updated_at desc limit 1;
  if v_id is null then
    return jsonb_build_object('ok', true, 'fechado', false, 'motivo', 'nenhuma conversa da Mari em handoff com esse id');
  end if;
  return public._mari_fechar_ciclo(v_id, 'conversa resolvida no Chatwoot');
end;
$$;
revoke execute on function public.mari_encerrar_ciclo(text) from public, anon, authenticated;
grant execute on function public.mari_encerrar_ciclo(text) to service_role;

-- mari_entrada (0013) + rede de segurança: conversa NOVA do Chatwoot para um contato em handoff fecha o ciclo antigo.
create or replace function public.mari_entrada(
  p_telefone text, p_nome text, p_texto text,
  p_canal text default 'teste', p_origem text default null,
  p_chatwoot_conversation_id text default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_tel  text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_conv public.mari_conversas;
  v_ts   timestamptz := clock_timestamp();
  v_orig text := case when p_origem in ('meta_ads', 'site', 'fila_vero', 'indicacao', 'direto', 'teste') then p_origem end;
  v_cw   text := nullif(btrim(coalesce(p_chatwoot_conversation_id, '')), '');
begin
  if v_tel !~ '^\d{10,15}$' then
    raise exception 'telefone inválido' using errcode = '22023';
  end if;

  select * into v_conv from public.mari_conversas
   where telefone = v_tel and canal = p_canal and status in ('ativo', 'handoff_realizado')
   for update;

  if not found then
    insert into public.mari_conversas (telefone, nome_contato, canal, origem, chatwoot_conversation_id)
    values (v_tel, nullif(btrim(p_nome), ''), p_canal,
            coalesce(v_orig, case when p_canal = 'teste' then 'teste' else 'direto' end),
            p_chatwoot_conversation_id)
    returning * into v_conv;
  elsif v_conv.status = 'handoff_realizado' and p_canal = 'whatsapp' and v_cw is not null
        and v_conv.chatwoot_conversation_id is distinct from v_cw then
    perform public._mari_fechar_ciclo(v_conv.id, 'nova conversa no Chatwoot (' || v_cw || ')');
    update public.mari_conversas set chatwoot_conversation_id = v_cw
     where id = v_conv.id returning * into v_conv;
  end if;

  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (v_conv.id, 'lead', coalesce(p_texto, ''), v_conv.status = 'ativo');

  update public.mari_conversas
     set ultima_entrada_ts = v_ts,
         ultima_msg_lead_at = now(),
         nome_contato = coalesce(nome_contato, nullif(btrim(p_nome), ''))
   where id = v_conv.id;

  return jsonb_build_object(
    'conversa_id', v_conv.id,
    'ts', v_ts,
    'status', v_conv.status,
    'silencio', v_conv.status <> 'ativo',          -- em handoff: humano conduz, Mari calada
    'nova', v_conv.created_at >= now() - interval '1 second');
end;
$$;

-- mari_handoff (0024) + venda_existente_id na duplicidade (prompt 18, B4). O resto é idêntico à 0024.
create or replace function public.mari_handoff(p_conversa uuid, p_motivo text, p_lead jsonb default '{}'::jsonb)
returns jsonb language plpgsql set search_path = public as $$
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

  -- Próximo passo do humano (venda remota, 05/11): sempre o mesmo texto, não depende do modelo.
  v_prox := case when p_motivo = 'dados_completos' then
    'Próximo passo: abrir pedido no portal PAP'
    || case when coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id') is not null
            then ' (interesse ' || coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id') || ' já criado na viabilidade)' else '' end
    || ' → mandar o link da biometria por esta conversa → agendar a instalação ('
    || coalesce(v_inst, 'preferência não informada') || ').' end;

  update public.mari_conversas set
    status = 'handoff_realizado', etapa = 'handoff', handoff_motivo = p_motivo, handoff_em = now(),
    handoff_briefing = concat_ws(E'\n', coalesce(nullif(btrim(l ->> 'briefing'), ''), handoff_briefing),
                                 case when p_motivo = 'dados_completos' or v_viab is not null then v_vnota end, v_prox),
    dados = d, processando_ate = null,
    instalacao_preferencia = coalesce(v_inst, instalacao_preferencia),
    nao_contatar = nao_contatar or p_motivo = 'recusa_compra',
    agendamento_retorno = coalesce((l ->> 'agendamento_retorno')::timestamptz, agendamento_retorno)
  where id = p_conversa
  returning * into c;

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
    v_orig := case when c.origem in ('meta_ads', 'site', 'fila_vero', 'indicacao') then c.origem else 'outro' end;
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
$$;
