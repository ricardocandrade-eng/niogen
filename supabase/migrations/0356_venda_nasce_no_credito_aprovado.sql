-- NIOGEN | supabase/migrations/0356_venda_nasce_no_credito_aprovado.sql | 22/11/2026 — Claude Code (Fable 5.2)
-- Caso L-219, depois da 0353 — Ricardo: "Gravou o nome, virou venda. Mas concorda que está muito contra intuitivo?" → proposta:
-- "crédito aprovado gravado em um lead conduzido pelo time já cria a venda sozinho… Plano, nome e complemento passam a ser
-- pendências da venda… O Virar venda fica só como reserva" → Ricardo: "Sim, fazer".
-- O problema: a ficha do lead mostra a mesma jornada da venda (crédito, biometria, OS), mas nada desses passos funcionava
-- enquanto alguém não lembrasse de apertar Virar venda — no L-219 isso travou o aviso, a biometria e a OS.
-- O que muda:
--  (1) mari_handoff__nucleo: com 'venda_incompleta' no pedido, a venda nasce sem plano e com nome provisório (o do WhatsApp).
--      As outras travas não mudam (elegibilidade, área, endereço, duplicidade). Sem o sinal, tudo como antes (a Mari e o Virar venda).
--  (2) _ged360_casar_venda: a leitura do GED360 que já existe para o CPF casa com a venda nova e vale na hora.
--  (3) _lead_venda_automatica + gatilho mari_conversas_credito_venda: lead SEM venda, em andamento, COM O TIME (dono, time ou
--      handoff), com CEP, número e CPF, crédito aprovado (todas, parcial ou só cartão; não o do endereço padrão), sem antifraude
--      aberto e sem 'ja_cliente'/'fora_area' → a venda nasce na hora em que o crédito é gravado (ficha, extensão ou robô) ou em
--      que o time assume um lead que a Mari já tinha consultado. Não deu (fora de área, duplicidade…): nada muda, fica lead, o
--      motivo vai para mari_erros e o Virar venda continua valendo. Com a Mari atendendo nada muda: ela cria a venda no handoff.
--  (4) Venda sem plano não grava OS (contaria com comissão zero): "Falta o plano desta venda…".
--  (5) venda_dados_do_portal: a extensão (0.11.0) completa também a VENDA com o que o humano digita no pedido — só o que está
--      vazio, só antes da OS, CPF diferente = recusa; o nome provisório é trocado pelo nome da Receita.
-- Regra 20: (1) nenhuma situação nova — a v_leads já punha esse lead em Qualificado · fazer pedido (vez do time, prazo da escada);
-- agora existe a venda que a tela prometia; (2) ninguém parado: o que falta aparece no turno de sistema e nas faltas da venda;
-- (3) nasce por função do banco (gatilho → mari_handoff pela porta), com evento venda_automatica_credito; (4) fonte: o crédito
-- do portal da Nio; (5) sem número novo — é uma venda como as outras, já conferida; medir pelo evento.
-- Muda os números (avisado ao Ricardo): lead com crédito aprovado que não fecha passa a ser venda em Qualificado → Saída.
-- Desempenho: sem impacto em tela. Cenário X82 (vermelho antes). Medição (7 dias): vendas 'venda_automatica_credito' que chegaram
-- à OS; 'virou_venda_niogen' → perto de 0; 'venda automática não criada' em mari_erros (motivos).
begin;

-- (1) o handoff aceita a venda incompleta quando quem pede é a venda automática
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
  v_inc    boolean := coalesce((coalesce(p_lead, '{}'::jsonb) ->> 'venda_incompleta')::boolean, false);   -- 0356: venda aberta sozinha no crédito aprovado
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
    -- 0356: com o time conduzindo e o crédito aprovado, a venda nasce mesmo sem plano e sem o nome do titular (pendências da venda)
    when v_plano.id is null and not v_inc then 'plano não escolhido'
    when coalesce(btrim(d ->> 'nome'), '') = '' and not v_inc then 'nome do cliente ausente'
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
      'Plano: ' || coalesce(v_plano.nome, 'a gravar') || ' · forma: ' || coalesce(v_forma, '?'),
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
        '0_qualificado', v_orig, 'mari:' || c.id,
        coalesce(nullif(btrim(d ->> 'nome'), ''), nullif(btrim(c.nome_contato), ''), 'Titular a confirmar'),   -- 0356: provisório até o nome da Receita
        nullif(v_cpf, ''), v_tel, nullif(btrim(d ->> 'email'), ''), v_seg,
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

-- (2) a leitura do GED360 que já existe para o CPF casa com a venda nova e vale na hora
create or replace function public._ged360_casar_venda(p_venda uuid, p_conversa uuid)
returns text language plpgsql security definer set search_path = public as $function$
declare
  c  public.mari_conversas;
  b  public.nio_biometria;
  ap jsonb;
begin
  select * into c from public.mari_conversas where id = p_conversa;
  if c.id is null or coalesce(public._so_digitos(c.dados ->> 'cpf'), '') = '' then return null; end if;
  update public.nio_biometria nb set venda_id = p_venda
   where nb.venda_id is null and nb.cpf_cnpj = public._so_digitos(c.dados ->> 'cpf')
     and coalesce(nb.data_envio, nb.primeira_leitura) > c.created_at - interval '1 hour';
  select * into b from public.nio_biometria
   where venda_id = p_venda and not coalesce(desconhecido, false)
   order by data_envio desc nulls last, id desc limit 1;
  if b.id is null then return null; end if;
  if exists (select 1 from public.eventos_venda e where e.venda_id = p_venda and e.tipo = 'biometria_ged360'
              and e.detalhe ->> 'protocolo' = b.protocolo and e.detalhe ->> 'para' = b.resultado) then
    return null;
  end if;
  insert into public.eventos_venda (venda_id, tipo, detalhe)
  values (p_venda, 'biometria_ged360', jsonb_build_object('protocolo', b.protocolo, 'para', b.resultado,
          'envio', b.data_envio, 'conferencia', b.data_conferencia));
  ap := public._ged360_aplicar(b);
  update public.nio_biometria set alerta = ap ->> 'alerta', alerta_nivel = ap ->> 'nivel',
    alerta_em = case when ap ->> 'alerta' is null then null else now() end, alerta_visto_em = null
  where id = b.id;
  return ap ->> 'feito';
end $function$;
revoke all on function public._ged360_casar_venda(uuid, uuid) from public, anon, authenticated;

-- (3) crédito aprovado com o time conduzindo → a venda nasce sozinha
create or replace function public._lead_venda_automatica(p_conversa uuid)
returns uuid language plpgsql security definer set search_path = public as $function$
declare
  c     public.mari_conversas;
  r     jsonb;
  v     uuid;
  falta text[];
  v_err text;
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found or c.venda_id is not null or c.canal is distinct from 'whatsapp' then return null; end if;
  if coalesce(c.credito_resultado, '') !~ '^(aprovado|cartao)' or coalesce(c.credito_endereco, '') = 'padrao' then return null; end if;
  -- só o lead que o TIME conduz: com a Mari atendendo, é ela quem cria a venda (handoff dados completos), como sempre
  if not (coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null
          or c.status = 'handoff_realizado') then return null; end if;
  if coalesce(c.funil_destino, 'em_andamento') <> 'em_andamento' or c.saida_motivo is not null or c.quadro_encerrada_motivo is not null then return null; end if;
  if c.elegibilidade is not null and c.elegibilidade <> 'ok' then return null; end if;   -- 'ja_cliente' e 'fora_area' da Mari barram
  if c.antifraude_situacao is not null then return null; end if;
  if c.cep is null or c.numero is null or coalesce(public._so_digitos(c.dados ->> 'cpf'), '') = '' then return null; end if;

  begin
    -- mesmas preparações do Virar venda (0236/0353): o handoff só cria venda com a conversa 'ativo' e a elegibilidade 'ok'
    update public.mari_conversas set elegibilidade = 'ok', status = 'ativo'
     where id = c.id and (elegibilidade is null or status <> 'ativo');
    r := public.mari_handoff(c.id, 'dados_completos', jsonb_build_object(
           'briefing', 'Venda aberta sozinha pelo NIOGEN: crédito aprovado com o time conduzindo a conversa.',
           'venda_incompleta', true));
    v := (r ->> 'venda_id')::uuid;
    if v is null then raise exception '%', coalesce(r ->> 'motivo_recusa', 'motivo desconhecido'); end if;
  exception when others then
    -- área, duplicidade, etc.: o bloco é desfeito (a conversa fica como estava) e o lead segue lead; o Virar venda continua valendo
    v_err := sqlerrm;
    insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
    values (c.id, 'venda_automatica', 'venda automática não criada: ' || v_err, jsonb_build_object('credito', c.credito_resultado));
    return null;
  end;

  falta := array_remove(array[
    case when not exists (select 1 from public.config_planos p where p.codigo = c.plano_escolhido) then 'plano' end,
    case when coalesce(btrim(c.dados ->> 'nome'), '') = '' then 'nome completo do titular' end,
    case when coalesce(btrim(c.forma_pagamento), '') = '' then 'forma de pagamento' end], null);
  insert into public.eventos_venda (venda_id, tipo, detalhe)
  values (v, 'venda_automatica_credito', jsonb_build_object('conversa_id', c.id, 'falta', to_jsonb(falta)));
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[venda aberta sozinha pelo NIOGEN: crédito aprovado com o time conduzindo'
          || case when coalesce(array_length(falta, 1), 0) > 0 then ' — falta gravar na venda: ' || array_to_string(falta, ', ') else '' end || ']', false);
  perform public._ged360_casar_venda(v, c.id);
  return v;
end $function$;
revoke all on function public._lead_venda_automatica(uuid) from public, anon, authenticated;

create or replace function public._lead_venda_automatica_trg()
returns trigger language plpgsql security definer set search_path = public as $function$
begin
  perform public._lead_venda_automatica(new.id);
  return null;
end $function$;

drop trigger if exists mari_conversas_credito_venda on public.mari_conversas;
create trigger mari_conversas_credito_venda
  after update of credito_resultado, humano_atribuido, time_atribuido, chatwoot_agente on public.mari_conversas
  for each row
  when (new.venda_id is null and new.credito_resultado is not null
        and (new.credito_resultado is distinct from old.credito_resultado
             or ((coalesce(new.humano_atribuido, false) or coalesce(new.time_atribuido, false) or new.chatwoot_agente is not null)
                 and not (coalesce(old.humano_atribuido, false) or coalesce(old.time_atribuido, false) or old.chatwoot_agente is not null))))
  execute function public._lead_venda_automatica_trg();

-- (4) venda sem plano não grava OS (a venda contaria com comissão zero): a mensagem diz o que fazer
create or replace function public._venda_os_pede_plano()
returns trigger language plpgsql set search_path = public as $function$
begin
  if new.plano_id is null and coalesce(btrim(new.nio_os), '') <> '' and coalesce(btrim(old.nio_os), '') = '' then
    raise exception 'Falta o plano desta venda: grave o plano na ficha (Trocar plano) antes de gravar a OS.';
  end if;
  return new;
end $function$;
drop trigger if exists vendas_a_os_pede_plano on public.vendas;
create trigger vendas_a_os_pede_plano before update of nio_os on public.vendas
  for each row execute function public._venda_os_pede_plano();

-- (5) o que o humano digitou no pedido do portal completa também a VENDA (antes da OS)
create or replace function public.venda_dados_do_portal(p_venda uuid, p_campos jsonb)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare
  v       public.vendas;
  c       public.mari_conversas;
  mud     text[] := '{}';
  fora    text[] := '{}';
  v_txt   text;
  v_dig   text;
  v_plano public.config_planos;
  v_prov  boolean;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into v from public.vendas where id = p_venda for update;
  if not found then raise exception 'Venda não encontrada.'; end if;
  if p_campos is null or jsonb_typeof(p_campos) <> 'object' then return jsonb_build_object('ok', true, 'mudou', '[]'::jsonb, 'resumo', 'Nada lido'); end if;
  -- depois da OS o que vale é o que foi para a Nio: nada é completado sozinho
  if v.status <> '0_qualificado' or coalesce(btrim(v.nio_os), '') <> '' then
    return jsonb_build_object('ok', true, 'mudou', '[]'::jsonb, 'resumo', 'Venda já com OS: nada gravado');
  end if;
  v_dig := regexp_replace(coalesce(p_campos ->> 'cpf', ''), '\D', '', 'g');
  if v_dig <> '' and coalesce(public._so_digitos(v.cliente_cpf_cnpj), '') <> '' and public._so_digitos(v.cliente_cpf_cnpj) <> v_dig then
    raise exception 'O CPF do pedido aberto no portal não é o desta venda: nada foi gravado.';
  end if;
  select * into c from public.mari_conversas where venda_id = v.id order by created_at desc limit 1;

  -- nome: só troca o PROVISÓRIO (venda nascida sem o nome do titular: a conversa ainda não tem dados.nome)
  v_prov := c.id is not null and coalesce(btrim(c.dados ->> 'nome'), '') = '';
  v_txt := nullif(btrim(p_campos ->> 'nome'), '');
  if v_txt is not null and v_txt ~ '\S+\s+\S+' and v_prov then
    if lower(btrim(v.cliente_nome)) is distinct from lower(v_txt) then v.cliente_nome := left(v_txt, 120); mud := array_append(mud, 'nome'); end if;
    update public.mari_conversas set dados = coalesce(dados, '{}'::jsonb) || jsonb_build_object('nome', left(v_txt, 120)) where id = c.id;
  end if;
  v_txt := nullif(lower(btrim(p_campos ->> 'email')), '');
  if v_txt is not null and coalesce(btrim(v.cliente_email), '') = '' and v_txt ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v.cliente_email := v_txt; mud := array_append(mud, 'e-mail'); end if;
  v_txt := nullif(btrim(p_campos ->> 'numero'), '');
  if v_txt is not null and coalesce(btrim(v.numero), '') = '' then v.numero := left(v_txt, 20); mud := array_append(mud, 'número'); end if;
  v_txt := nullif(btrim(p_campos ->> 'complemento'), '');
  if v_txt is not null and coalesce(btrim(v.complemento), '') = '' then v.complemento := left(v_txt, 60); mud := array_append(mud, 'complemento'); end if;
  v_txt := nullif(btrim(p_campos ->> 'rua'), '');
  if v_txt is not null and coalesce(btrim(v.logradouro), '') = '' then v.logradouro := left(v_txt, 120); mud := array_append(mud, 'rua'); end if;
  v_txt := nullif(btrim(p_campos ->> 'referencia'), '');
  if v_txt is not null and coalesce(btrim(v.ponto_referencia), '') = '' then v.ponto_referencia := left(v_txt, 120); mud := array_append(mud, 'referência'); end if;
  v_txt := nullif(btrim(p_campos ->> 'forma'), '');
  if v_txt is not null and v.forma_pagamento is null and v_txt in ('boleto', 'cartao', 'dacc') then v.forma_pagamento := v_txt; mud := array_append(mud, 'pagamento'); end if;
  v_txt := nullif(btrim(p_campos ->> 'plano'), '');
  if v_txt is not null and v.plano_id is null then
    select * into v_plano from public.config_planos where codigo = v_txt and ativo;
    if not found then fora := array_append(fora, 'plano fora da tabela vigente');
    else v.plano_id := v_plano.id; mud := array_append(mud, 'plano'); end if;
  end if;

  if array_length(mud, 1) is null then
    return jsonb_build_object('ok', true, 'mudou', '[]'::jsonb, 'fora', to_jsonb(fora), 'resumo', 'Nada novo para gravar');
  end if;
  update public.vendas
     set cliente_nome = v.cliente_nome, cliente_email = v.cliente_email, numero = v.numero, complemento = v.complemento,
         logradouro = v.logradouro, ponto_referencia = v.ponto_referencia, forma_pagamento = v.forma_pagamento, plano_id = v.plano_id
   where id = v.id;
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (v.id, 'dados_do_portal', jsonb_build_object('campos', to_jsonb(mud), 'origem', 'extensao'), auth.uid());
  return jsonb_build_object('ok', true, 'mudou', to_jsonb(mud), 'fora', to_jsonb(fora),
                            'resumo', '✓ Gravado na venda (do portal): ' || array_to_string(mud, ', '));
end $function$;
revoke all on function public.venda_dados_do_portal(uuid, jsonb) from public, anon;
grant execute on function public.venda_dados_do_portal(uuid, jsonb) to authenticated;

commit;
