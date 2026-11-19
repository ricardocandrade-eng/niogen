-- NIOGEN | supabase/migrations/0313_pedido_outra_revenda_fica_com_o_time.sql | 19/11/2026 — Claude Code (Opus 5.5)
-- Caso Michele (Chatwoot 76), achado pela sombra do projetor: marcada "já é cliente Nio", mas ela não é — tem um pedido Nio aberto de
-- outra revenda, que não quer mais, e prefere comprar com a gente. O crédito voltou "pedido em andamento" e _funil_calcular tratava isso
-- como cliente Nio (decisões 2 e 3 do começo): Saída definitiva, conversa silenciada, sem dono. 6 leads assim (76, 120, 137, 58, 157, 148).
-- Ricardo, 19/11: "Fica com o time" · "Sim, monte".
-- O que muda:
--  (1) _funil_calcular: pedido em andamento não é mais cliente Nio. O lead segue em andamento, no passo do crédito, vez do time; a ficha
--      e a nota da Mari já dizem "NÃO abrir outro pedido: conferir no portal o pedido que já existe no CPF". A Mari (n8n) não muda: ela já
--      pergunta ao cliente do pedido aberto (Bloco 9) e passa ao time.
--  (2) mari_credito_gravar e lead_registrar_consulta: crédito decidido de novo (aprovado ou negado) limpa a marca de pedido aberto.
--  (3) config_transicao: Reabrir em "Cliente Nio" passa a existir, só admin (com motivo) — para quem foi marcado errado.
--  (4) Os 6 leads voltam pela porta (Reabrir, como admin, com motivo): conversa e venda saem da Saída; o projetor da porta ajusta o Chatwoot.
-- A opção "pedido Nio em andamento" sai do menu de Saída "Já é cliente Nio" (ficha.js e app.js, no mesmo commit).
-- Regra 20: (1) nenhuma tabela nova; (2) o destino muda pela porta (Reabrir); (3) tela: menu de Saída; botão Reabrir aparece para admin
-- em Cliente Nio; (4) desempenho: sem impacto. Cenário X44.
begin;

CREATE OR REPLACE FUNCTION public._funil_calcular(c mari_conversas)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  v        public.vendas;
  tel      text := regexp_replace(coalesce(c.telefone, ''), '\D', '', 'g');
  teste    boolean;
  viavel   boolean; viav_pend boolean; cliente boolean;
  pedido   boolean; bio boolean; agendada boolean; instalada boolean; qualif boolean; viu boolean;
  respondeu boolean := false;
  etapa    text;
  duro     text; duro_det text;
  evento   text; evento_det text;
  quadro   text := public._funil_destino_quadro(c.quadro_encerrada_motivo);
  hand     text := public._funil_destino_handoff(c.handoff_motivo);
begin
  if c.venda_id is not null then select * into v from public.vendas where id = c.venda_id; end if;
  teste := coalesce(c.canal, '') = 'teste' or tel like '5500000000%'
        or tel = any (coalesce((select array_remove(regexp_split_to_array(regexp_replace(coalesce(texto, ''), '[^0-9,]', '', 'g'), ','), '')
                                  from public.config_mari_textos where chave = 'telefones_teste'), '{}'::text[]));
  viavel    := coalesce(c.cobertura_decisao in ('viavel', 'elegivel_200m') or c.nio_viab_resultado = 'viavel' or v.nio_viab_resultado = 'viavel', false);
  viav_pend := coalesce(c.cobertura_decisao = 'unidade_fora_lista', false);       -- decisão 1: viável com pendência (não qualifica sozinha)
  pedido    := coalesce(v.nio_pedido is not null or v.nio_os is not null
            or v.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme'), false);
  -- 0313 (Ricardo, 19/11: "Fica com o time"): pedido Nio em andamento de OUTRA revenda não é cliente Nio — o lead segue com o time
  -- (cancelar o pedido de lá e rodar o crédito de novo). Antes (decisões 2 e 3): virava "já é cliente Nio".
  cliente   := coalesce(c.elegibilidade = 'ja_cliente' or c.handoff_motivo = 'ja_cliente_nio' or c.quadro_encerrada_motivo = 'suporte_nio', false);
  bio       := v.biometria_status = 'validada';
  agendada  := v.instalacao_agendada_para is not null or v.status in ('2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme');
  instalada := v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme');
  viu       := c.plano_escolhido is not null or c.etapa in ('planos', 'coleta', 'resumo') or c.handoff_motivo = 'dados_completos' or v.id is not null;
  qualif    := coalesce(c.handoff_motivo = 'dados_completos' or v.id is not null, false) and viavel and not cliente
            and coalesce(c.credito_resultado, '') not like 'negado%' and coalesce(v.motivo_saida, '') !~* 'cr[eé]dito';
  if c.id is not null and c.ultima_msg_lead_at is not null and coalesce(c.funil_etapa, 'nova') = 'nova' then
    select count(*) >= 2 into respondeu from (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' limit 2) x;
  end if;

  etapa := case
    when coalesce(instalada, false) then 'instalada'
    when coalesce(agendada, false)  then 'agendada'
    when coalesce(bio, false)       then 'biometria'
    when coalesce(pedido, false)    then 'pedido'
    when coalesce(qualif, false)    then 'qualificada'
    when coalesce(viu, false)       then 'viu_planos'
    when coalesce(viavel or viav_pend, false) then 'viavel'
    when c.dentro_area is true      then 'area_ok'
    when c.cep is not null          then 'cep'
    when respondeu or coalesce(c.funil_etapa, 'nova') <> 'nova' then 'respondeu'
    else 'nova' end;

  -- saída dura (na ordem de prioridade)
  if teste then duro := 'teste_duplicada'; duro_det := 'telefone ou canal de teste';
  elsif coalesce(instalada, false) then duro := 'instalada'; duro_det := 'instalada';
  elsif cliente then duro := 'ja_cliente_nio';
    duro_det := case when c.quadro_encerrada_motivo = 'suporte_nio' then 'suporte Nio'
                     when c.elegibilidade = 'ja_cliente' or c.handoff_motivo = 'ja_cliente_nio' then 'elegibilidade: já cliente'
                     else 'pedido Nio em andamento (não é nosso)' end;
  elsif c.dentro_area is false or c.elegibilidade = 'fora_area' then duro := 'fora_area'; duro_det := 'CEP fora da área';
  elsif c.cobertura_decisao = 'sem_cobertura'
        or (c.nio_viab_resultado = 'sem_viabilidade' and coalesce(c.cobertura_decisao, '') not in ('viavel', 'elegivel_200m')) then
    duro := 'sem_cobertura'; duro_det := 'viabilidade: sem cobertura';   -- 0151: operador elegível (fachada a ≤ 200 m) vence o portal
  -- 0252 (H1, Ricardo 17/11: "Venda segue, sem mensagens"): com venda viva, Não contatar NÃO é Saída — a venda segue,
  -- só as mensagens param. Sem venda (ou venda em Saída), continua Recusou.
  elsif coalesce(c.nao_contatar, false) and (v.id is null or v.status = 'saida') then duro := 'recusou'; duro_det := 'não contatar';
  end if;

  -- saída de evento: cada fonte em separado (o gatilho só aplica a fonte que acabou de mudar) + a primeira pela prioridade
  return jsonb_build_object('etapa', etapa, 'duro', duro, 'duro_det', duro_det,
    'venda',   case when v.status = 'saida' then public.funil_destino_de_motivo(v.motivo_saida) end,
    'venda_det', 'venda: ' || coalesce(v.motivo_saida, 'sem motivo'),
    'quadro',  quadro, 'quadro_det', 'Saída da conversa: ' || c.quadro_encerrada_motivo,
    'hand',    hand,   'hand_det', 'Mari: ' || c.handoff_motivo,
    'cad',     case when c.cadencia_passo = 'encerrada' then 'sem_resposta' end, 'cad_det', 'cadência esgotada',
    'evento',  coalesce(case when v.status = 'saida' then public.funil_destino_de_motivo(v.motivo_saida) end, quadro, hand,
                        case when c.cadencia_passo = 'encerrada' then 'sem_resposta' end),
    'evento_det', case when v.status = 'saida' then 'venda: ' || coalesce(v.motivo_saida, 'sem motivo')
                       when quadro is not null then 'Saída da conversa: ' || c.quadro_encerrada_motivo
                       when hand is not null then 'Mari: ' || c.handoff_motivo
                       when c.cadencia_passo = 'encerrada' then 'cadência esgotada' end);
end;
$function$;

CREATE OR REPLACE FUNCTION public.mari_credito_gravar(p_conversa uuid, p_saida jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_op text := p_saida->>'resultado'; v text; c record; v_formas text; v_fp text; v_fazer text;
        v_end text := case when p_saida->'endereco'->>'origem' = 'cliente' then 'cliente' when p_saida->'endereco'->>'origem' = 'padrao' then 'padrao' end;
begin
  if coalesce(p_saida->>'retry', '') = 'true' then
    update public.mari_conversas set credito_em = null, credito_consultas = greatest(credito_consultas - 1, 0)
     where id = p_conversa and credito_resultado is null;
    return jsonb_build_object('ok', true, 'resultado', 'de_volta_na_fila');
  end if;
  v := case when v_op in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'negado_antifraude', 'pedido_em_andamento')
            then v_op else 'nao_decidiu' end;
  update public.mari_conversas set credito_resultado = v, credito_em = now(), credito_endereco = v_end,
         credito_formas = case when jsonb_typeof(p_saida->'formas_liberadas') = 'array' then p_saida->'formas_liberadas' end,
         nio_pedido_aberto = case when v = 'pedido_em_andamento' then 'sim' when v in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'negado', 'negado_antifraude') then 'nao' else nio_pedido_aberto end   -- 0313: crédito decidido = o pedido de lá caiu
   where id = p_conversa returning id, venda_id, credito_autorizado_em, credito_autorizacao_frase, chatwoot_conversation_id, status,
                                   forma_pagamento, credito_consultas into c;
  if c.id is null then return jsonb_build_object('ok', false, 'motivo', 'conversa não encontrada'); end if;
  insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cpf_mascara, resultado, detalhe, ms)
  values ('credito', 'mari', p_conversa, c.venda_id, p_saida->>'cpf_mascara', coalesce(v_op, 'erro'),
          jsonb_strip_nulls(jsonb_build_object('formas', p_saida->'formas_liberadas', 'motivo', p_saida->>'motivo',
            'cache', p_saida->'cache', 'etapa_parada', p_saida->'etapa_parada', 'endereco', v_end,
            'autorizado_em', c.credito_autorizado_em, 'autorizacao_frase', c.credito_autorizacao_frase)),
          nullif(p_saida->>'ms', '')::int);
  -- 0140: o resultado chegou depois do handoff (a nota da Mari já foi) → nota interna no Chatwoot pela fila do NIOGEN.
  if c.chatwoot_conversation_id is not null and (c.status = 'handoff_realizado' or c.venda_id is not null or v = 'negado_antifraude') then   -- 0212: antifraude sempre vira nota
    v_formas := (select string_agg(case upper(x) when 'BOLETO' then 'boleto' when 'CREDITO' then 'cartão' when 'DACC' then 'débito em conta' else lower(x) end, ', ')
                   from jsonb_array_elements_text(case when jsonb_typeof(p_saida->'formas_liberadas') = 'array' then p_saida->'formas_liberadas' else '[]'::jsonb end) x);
    v_fp := case c.forma_pagamento when 'boleto' then 'boleto' when 'cartao' then 'cartão' when 'debito' then 'débito em conta' end;
    v_fazer := case
      when v = 'negado_antifraude' then 'NÃO consultar outro CPF. Perguntar ao cliente se a Nio do endereço é dele (ou de alguém da casa) ou de outro morador que se mudou; gravar a resposta na ficha › Crédito (Antifraude).'
      when v = 'pedido_em_andamento' then 'NÃO abrir outro pedido: conferir no portal o pedido que já existe no CPF (recompra = multa R$ 500).'
      when v_end = 'padrao' and v like 'aprovado%' then 'Consultar o crédito de novo no endereço do cliente (ficha › Crédito) antes de abrir o pedido.'
      when v = 'nao_decidiu' then 'Consultar o crédito na ficha (Crédito) — o portal não decidiu.'
      when v = 'pendente' then 'Aguardar a resposta da Nio (até 24 h) e avisar o cliente; não abrir o pedido antes.'
      when v = 'negado' and coalesce(c.credito_consultas, 0) >= 2 then 'Ver com o cliente outra pessoa da casa como titular; sem saída, encerrar pela Saída.'
      when v = 'negado' then 'Oferecer outra pessoa da casa como titular (CPF do parente → 1 nova consulta).'
      when v = 'aprovado_cartao' and coalesce(c.forma_pagamento, '') <> 'cartao' then 'Só o cartão foi liberado: confirmar se o cliente paga no cartão; se não, outra pessoa da casa como titular.'
      when v = 'aprovado_parcial' and c.forma_pagamento in ('boleto', 'cartao', 'debito')
           and not coalesce(p_saida->'formas_liberadas', '[]'::jsonb) ? (case c.forma_pagamento when 'boleto' then 'BOLETO' when 'cartao' then 'CREDITO' else 'DACC' end)
        then 'A forma escolhida (' || v_fp || ') não foi liberada: combinar com o cliente uma das liberadas (' || coalesce(v_formas, '?') || ').'
      else 'Gravar o crédito na ficha e abrir o pedido no portal' || coalesce(' no ' || v_fp, '') || '; avisar o cliente do link da biometria que a Nio manda.' end;
    insert into public.chatwoot_acoes (grupo, ordem, momento, venda_id, conversa_id, chatwoot_conversation_id, tipo, payload, status)
    values (gen_random_uuid(), 1, 'credito', c.venda_id, p_conversa, c.chatwoot_conversation_id, 'nota',
            jsonb_build_object('content', '💳 Crédito chegou (consulta automática da Mari'
              || coalesce(', ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), '') || '): '
              || case v when 'aprovado_todas' then 'APROVADO — todas as formas'
                        when 'aprovado_parcial' then 'APROVADO — ' || coalesce(v_formas, 'formas: ?')
                        when 'aprovado_cartao' then 'APROVADO SÓ NO CARTÃO'
                        when 'pendente' then 'PENDENTE (a Nio responde em até 24 h)'
                        when 'negado' then case when coalesce(c.credito_consultas, 0) >= 2 then 'NEGADO nos 2 CPFs (titular e parente)' else 'NEGADO neste CPF' end
                        when 'negado_antifraude' then 'NEGADO — CRITÉRIOS ANTIFRAUDE (a Nio vê Nio neste endereço)'
                        when 'pedido_em_andamento' then 'já existe PEDIDO NIO EM ANDAMENTO no CPF'
                        else 'o portal não decidiu' end
              -- 0204: lido no endereço padrão → não vale para o endereço do cliente
              || case when v_end = 'padrao' and v like 'aprovado%' then ' · ⚠ lido no endereço PADRÃO, não no do cliente' else '' end
              || E'\n👉 Fazer agora: ' || v_fazer), 'pendente');
  end if;
  return jsonb_build_object('ok', true, 'resultado', v, 'endereco', v_end);
end $function$;

CREATE OR REPLACE FUNCTION public.lead_registrar_consulta(p_conversa uuid, p_tipo text, p_resultado text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c    public.mari_conversas;
  rot  text;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null then raise exception 'Este lead já tem venda: registre na venda.'; end if;

  if p_tipo = 'viabilidade' then
    if p_resultado <> 'viavel' then
      raise exception 'Por aqui só se grava "viável". Sem viabilidade: use Saída › Fachada não atendida.';
    end if;
    update public.mari_conversas
       set nio_viab_resultado = 'viavel', nio_viab_em = now(),
           cobertura_decisao = 'viavel', cobertura_em = now(),
           cobertura_detalhe = coalesce(cobertura_detalhe, '{}'::jsonb) || jsonb_build_object('portal', 'viavel', 'registrado_na_ficha', true),
           rua_conferir_em = null   -- 0202: viável registrado na ficha = rua conferida
     where id = c.id;
    insert into public.operador_consultas (tipo, origem, usuario_id, conversa_id, cep, numero, complemento, resultado, decisao, detalhe)
    values ('viabilidade', 'tela', auth.uid(), c.id, c.cep, c.numero, c.complemento, 'viavel', 'viavel', jsonb_build_object('registrado_na_ficha', true));
    rot := 'viabilidade: viável';

  elsif p_tipo = 'credito' then
    if p_resultado not in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'negado_antifraude', 'pedido_em_andamento') then
      raise exception 'Resultado de crédito desconhecido: %', p_resultado;
    end if;
    update public.mari_conversas
       set credito_resultado = p_resultado, credito_em = now(),
           nio_pedido_aberto = case when p_resultado = 'pedido_em_andamento' then 'sim' when p_resultado in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'negado', 'negado_antifraude') then 'nao' else nio_pedido_aberto end   -- 0313
     where id = c.id;
    insert into public.operador_consultas (tipo, origem, usuario_id, conversa_id, resultado, detalhe)
    values ('credito', 'tela', auth.uid(), c.id, p_resultado, jsonb_build_object('registrado_na_ficha', true));
    rot := 'crédito: ' || case p_resultado when 'aprovado_todas' then 'aprovado' when 'aprovado_parcial' then 'aprovado (parcial)'
                                           when 'aprovado_cartao' then 'aprovado só no cartão' when 'pendente' then 'pendente'
                                           when 'negado' then 'negado' when 'negado_antifraude' then 'negado por critérios antifraude — conferir com o cliente' else 'já tem pedido em andamento' end;
  else
    raise exception 'Tipo desconhecido: %', p_tipo;
  end if;

  return jsonb_build_object('ok', true, 'resumo', '✓ registrado no lead — ' || rot);
end;
$function$;

-- (3) Reabrir em Cliente Nio — só o admin, com motivo
insert into public.config_transicao (evento, de, para, aceito, frase, nota, exige)
select 'reabrir', 'cliente_nio', array['andamento'], true,
       'Só o admin reabre quem está como cliente Nio (quando ele não é cliente — por exemplo, pedido de outra revenda).',
       '0313 (Ricardo, 19/11): pedido de outra revenda não é cliente Nio', 'admin'
 where not exists (select 1 from public.config_transicao where evento = 'reabrir' and de = 'cliente_nio');

-- (4) os leads marcados por pedido em andamento voltam pela porta, como admin, com motivo
do $$
declare r record; adm uuid; res jsonb; n int := 0;
begin
  select id into adm from public.usuarios where perfil = 'admin' order by id limit 1;
  perform set_config('request.jwt.claims', jsonb_build_object('role', 'authenticated', 'sub', adm)::text, true);
  for r in
    select m.id, m.venda_id from public.mari_conversas m
     where m.funil_destino = 'ja_cliente_nio'
       and (m.credito_resultado = 'pedido_em_andamento' or m.nio_pedido_aberto = 'sim' or m.saida_sub = 'pedido Nio em andamento')
       and coalesce(m.elegibilidade, '') <> 'ja_cliente' and coalesce(m.handoff_motivo, '') <> 'ja_cliente_nio'
       and (m.quadro_encerrada_motivo is distinct from 'suporte_nio' or m.saida_sub = 'pedido Nio em andamento')   -- a Saída à mão marcava suporte
     order by m.created_at
  loop
    res := public.porta('reabrir', r.id, r.venda_id,
      jsonb_build_object('motivo', '0313: pedido Nio de outra revenda não é cliente Nio — fica com o time (Ricardo, 19/11)'));
    n := n + 1;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  raise notice '0313: % leads reabertos', n;
end $$;

select public.porta_divergencias_rever();

commit;
