-- NIOGEN | supabase/migrations/0348_mari_marca_a_espera_com_data.sql | 21/11/2026 — Claude Code (Opus 5.5)
-- Caso L-199 (Bruno Barcelos, 20/11 20h35: "Vou decidir com calma, temos até dia 18/12 para tomar decisões, pq nossa mudança será
-- dia 17/12"). Ricardo, 21/11: "Preciso criar uma forma de controlar isso. E a cadência nesse caso, como fica?" → "Sim, faz aqui".
-- A Mari entendeu a data (está no briefing dela), mas nada foi gravado: o C3 (múltiplos decisores / interesse caindo, 0266) volta
-- antes de ler o [AGENDAMENTO_RETORNO], e o lead seguia exposto à escada e ao 🔥 O10 (3 dias), contra o "perto do dia a gente te chama".
--  (1) _mari_espera(conversa, data do cliente): a Mari marca a ⏸ espera sozinha — volta para o Live N dias antes da data do cliente
--      (config_regras.mari_espera_antecedencia_dias, padrão 7; no mínimo amanhã, no máximo 60 dias), às 9h, com o motivo
--      "cliente decide até DD/MM". Mesmo efeito da espera do time (0101): escada, retomada e O10 param; nota e adiamento no Chatwoot.
--      espera_por nulo = marcada pela Mari. Repetir o mesmo dia não faz nada (a Mari repete o C3 a cada "ok").
--  (2) mari_handoff__nucleo: o C3 chama a (1) com o agendamento_retorno do lead (o resto igual à produção de 21/11).
--  (3) _porta_turno_cliente: a espera da Mari não cai com "ok"/"valeu"/emoji até 2 h depois de marcada (o "😉" do Bruno).
--  (4) config_transicao: 'aguardar' em mari_atendendo → em_espera (antes sem regra); o C3 (mari_passou:interesse_caindo /
--      multiplos_decisores) pode ir para em_espera além de ficar onde está.
-- Regra 20: (1) situação em_espera já existe, com vez (time) e prazo (a data); (2) saída automática: volta ao Live no dia, ou antes se
-- o cliente escrever; (3) quem grava é a função do banco, com motivo e autor (turno sistema "marcado pela Mari" + porta_sombra
-- 'aguardar'); (4) fonte: a fala do cliente, pela Mari; (5) conferência: o cenário X74 no portão; a espera aparece no Live/Acompanhando
-- como toda espera. Contrato: nada sai para o cliente.
begin;

insert into public.config_regras (chave, valor, descricao) values
  ('mari_espera_antecedencia_dias', '7'::jsonb,
   '0348: quando o cliente dá uma data ("decido até 18/12"), a Mari marca a espera e o lead volta para o Live N dias antes dela')
on conflict (chave) do nothing;

insert into public.config_transicao (evento, de, para, aceito, frase, nota, exige) values
  ('aguardar', 'mari_atendendo', array['em_espera'], true, null, '0348: a Mari marca a espera quando o cliente dá uma data', null)
on conflict do nothing;
-- o C3 continua com a Mari ("="), e com uma data do cliente vai para a espera
update public.config_transicao set para = array['=', 'em_espera'], nota = 'C3 (0266): fica com a Mari · 0348: com data do cliente, em espera'
 where de = 'andamento' and evento in ('mari_passou:interesse_caindo', 'mari_passou:multiplos_decisores');

create or replace function public._mari_espera(c public.mari_conversas, p_retorno text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  hoje  date := (now() at time zone 'America/Sao_Paulo')::date;
  ant   int  := coalesce(nullif(public._bo_cfg('mari_espera_antecedencia_dias', '7'::jsonb) #>> '{}', '')::int, 7);
  v_cli date;
  v_dia date;
  v_ate timestamptz;
  v_mot text;
  antes text;
  g     uuid := gen_random_uuid();
  r     jsonb;
begin
  begin
    v_cli := (substring(coalesce(p_retorno, '') from '\d{4}-\d{2}-\d{2}'))::date;
  exception when others then v_cli := null;
  end;
  if v_cli is null or v_cli <= hoje or c.venda_id is not null or coalesce(c.nao_contatar, false) then return null; end if;
  v_dia := greatest(hoje + 1, least(v_cli - ant, hoje + 60));
  if c.espera_ate is not null and c.espera_ate > now() and (c.espera_ate at time zone 'America/Sao_Paulo')::date = v_dia then
    return jsonb_build_object('ok', true, 'repetida', true, 'ate', v_dia);
  end if;
  v_ate := (v_dia::text || ' 09:00')::timestamp at time zone 'America/Sao_Paulo';
  v_mot := 'cliente decide até ' || to_char(v_cli, 'DD/MM');
  antes := public._porta_situacao(c.id, null::uuid);
  update public.mari_conversas
     set espera_ate = v_ate, espera_motivo = v_mot, espera_em = now(), espera_por = null
   where id = c.id;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[em espera até ' || to_char(v_dia, 'DD/MM') || ' — ' || v_mot || ' — marcado pela Mari]', false);
  if coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%' then
    perform public._bo_enfileirar(g, 1, 'espera', null, c, 'nota', jsonb_build_object('content',
      '⏸ Em espera até ' || to_char(v_dia, 'DD/MM') || ' — ' || v_mot || ' (marcado pela Mari). Volta para o Live no dia, '
      || 'ou antes se o cliente escrever. Combinado com o cliente: perto da data, o nosso time chama.'));
    perform public._bo_enfileirar(g, 2, 'espera', null, c, 'resolver',
      jsonb_build_object('status', 'snoozed', 'snoozed_until', extract(epoch from v_ate)::bigint));
  end if;
  r := jsonb_build_object('ok', true, 'ate', v_dia, 'cliente', v_cli, 'motivo', v_mot);
  perform public._porta_anotar('aguardar', 'mari_handoff', c.id, null::uuid, antes, r);
  return r;
end $$;
revoke execute on function public._mari_espera(public.mari_conversas, text) from public, anon, authenticated;

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
  v_esp    jsonb;   -- 0348: espera marcada pela Mari
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
    -- 0348 (caso L-199, Bruno: "temos até dia 18/12 para tomar decisões"): o cliente deu uma data → a Mari marca a espera
    -- (⏸) sozinha. Antes, o [AGENDAMENTO_RETORNO] se perdia aqui e o lead seguia na escada e no 🔥 O10.
    v_esp := public._mari_espera(c, l ->> 'agendamento_retorno');
    return jsonb_build_object('ok', true, 'fica_com_mari', true, 'venda_id', c.venda_id, 'espera', v_esp);
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
    v_orig := case when c.origem not in ('direto', 'desconhecida', 'teste', 'parceiro_pap', 'outro')
                     and exists (select 1 from public.config_canais k where k.canal = c.origem) then c.origem else 'outro' end;   -- 0302: canal novo vai para a venda
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

CREATE OR REPLACE FUNCTION public._porta_turno_cliente()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare antes text; r jsonb; dentro boolean := coalesce(current_setting('porta.dentro', true), '') <> '';
begin
  -- 0274: o cliente respondeu durante a Retomada → ela fecha (a conversa segue com quem tinha: dono guardado ou a Mari)
  update public.mari_conversas set retomada_fim_em = now(), retomada_fim = 'respondeu'
   where id = new.conversa_id and retomada_desde is not null and retomada_fim_em is null and new.created_at >= retomada_desde;
  if found then
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (new.conversa_id, 'sistema', '[o cliente respondeu à Retomada — ela fecha; a conversa segue com quem tinha]', false);
  end if;
  if not exists (select 1 from public.mari_conversas m where m.id = new.conversa_id and m.espera_ate is not null and m.espera_ate > now()) then
    return null;
  end if;
  -- 0348 (L-199: o "😉" logo depois da despedida): espera que a MARI marcou (espera_por nulo) não cai com um "ok", "valeu" ou
  -- emoji mandado até 2 h depois de marcada — a espera segue, e o relógio da espera passa para esta fala (as telas comparam
  -- ultima_msg_lead_at com espera_em). Qualquer outra fala, ou depois de 2 h, encerra como sempre (C11).
  if exists (select 1 from public.mari_conversas m where m.id = new.conversa_id and m.espera_por is null
               and m.espera_em > now() - interval '2 hours')
     and public._saida_so_confirmacao(new.texto) then
    update public.mari_conversas set espera_em = now() where id = new.conversa_id;
    return null;
  end if;
  antes := public._porta_situacao(new.conversa_id, null::uuid);
  r := public.porta('cliente_escreveu', new.conversa_id, null::uuid, '{"acao": "fim_espera"}'::jsonb);
  if not dentro then   -- pela mari_entrada a casca já anota o evento
    perform public._porta_anotar('cliente_escreveu', '_porta_turno_cliente', new.conversa_id, null::uuid, antes, r);
  end if;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_porta_turno_cliente', new.conversa_id::text || ': ' || sqlerrm);
  return null;
end $function$;

commit;
