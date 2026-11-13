-- NIOGEN | supabase/migrations/0153_estancar_1a.sql | 12/11/2026 — Claude Code (Fable 5.2)
-- Prompt: docs/Prompt_estancar_1a_121126_2230.md (Drive) · Plano: docs/PLANO_sistema_fechado_etapas_121126_2135.md, etapa 1a.
-- Resultado buscado: ninguém parado em silêncio. NÃO toca a Mari nem a cadência (o teste da cadência está em curso).
-- O quê:
--   1. backoffice_conversa: conversa com destino "instalada" pode ser resolvida pelo NIOGEN (antes a trava recusava).
--   2. aplicar_osab: venda em 1_vendido também avança quando a Nio conclui; a data de fechamento do OSAB vence a hora da leitura.
--   3. v_funil.horas_sem_agendamento: o relógio das 4 h conta da biometria validada mesmo sem nº de pedido (desde a 0111 o
--      pedido só existe com a OS; a condição antiga zerava o contador do Painel).
--   4. funil_alerta ganha "atribuida_fora_niogen" e "adiada_fora_niogen" (gatilho no espelho do Chatwoot).
--   5. live_conferir(): lista "Conferir" da Live — ação do Chatwoot que falhou, conversa mexida fora do NIOGEN, conversa
--      parada com dono, documentos de 15 dias. chatwoot_acao_retentar / _dispensar e conversa_alerta_visto.
-- Corpo de 1, 2 e 3 = definição viva do banco em 12/11 com só os trechos marcados "0153" trocados.

-- ───────────────────────── 1. resolver conversa instalada ─────────────────────────
CREATE OR REPLACE FUNCTION public.backoffice_conversa(p_conversa uuid, p_acao text, p_valor text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

declare

  c      public.mari_conversas;

  g      uuid := gen_random_uuid();

  v_time int := (public._bo_cfg('chatwoot_time_backoffice', '15102') #>> '{}')::int;

  lab    text;

begin

  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then

    raise exception 'Só admin ou backoffice.' using errcode = '42501';

  end if;

  select * into c from public.mari_conversas where id = p_conversa;

  if not found or coalesce(c.chatwoot_conversation_id, '') = '' then raise exception 'Conversa sem Chatwoot.'; end if;

  if c.telefone like '5500000000%' then raise exception 'Telefone de teste: nada vai ao Chatwoot.'; end if;

  if p_acao = 'atribuir' then

    if p_valor = 'eu' then return public.backoffice_momento(null, 'assumir', jsonb_build_object('conversa_id', c.id)); end if;

    if p_valor = 'mari' then return public.backoffice_momento(null, 'devolver_mari', jsonb_build_object('conversa_id', c.id)); end if;

    if p_valor = 'time' then

      perform public.mari_cadencia_parar(c.id, p_time => true);

      perform public._bo_enfileirar(g, 1, 'atribuir', c.venda_id, c, 'desatribuir', jsonb_build_object('assignee_id', null));

      perform public._bo_enfileirar(g, 2, 'atribuir', c.venda_id, c, 'atribuir', jsonb_build_object('team_id', v_time));

      return jsonb_build_object('ok', true, 'resumo', '✓ conversa no time backoffice (a Mari calou)');

    end if;

    raise exception 'Atribuição inválida.';

  elsif p_acao = 'status' then

    if p_valor not in ('open', 'resolved') then raise exception 'Status inválido.'; end if;

    if p_valor = 'resolved' and coalesce(c.funil_destino, 'em_andamento') = 'em_andamento' then   -- 0153: instalada pode ser resolvida

      raise exception 'Para resolver, registre o destino: ficha da conversa → Saída (ou Saída da venda). Conversa sem destino não se resolve.';

    end if;

    perform public._bo_enfileirar(g, 1, 'status', c.venda_id, c, 'resolver', jsonb_build_object('status', p_valor));

    return jsonb_build_object('ok', true, 'resumo', case when p_valor = 'resolved' then '✓ conversa resolvida' else '✓ conversa reaberta' end);

  elsif p_acao in ('etiqueta_add', 'etiqueta_remove') then

    lab := lower(btrim(coalesce(p_valor, '')));

    if lab !~ '^[a-z0-9_-]{2,40}$' then raise exception 'Etiqueta inválida.'; end if;

    if lab like 'saida-%' then raise exception 'Etiqueta de saída é do NIOGEN: registre o destino pela Saída.'; end if;

    perform public._bo_enfileirar(g, 1, 'etiqueta', c.venda_id, c, 'etiquetas',

      case when p_acao = 'etiqueta_add' then jsonb_build_object('add', jsonb_build_array(lab))

           else jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array(lab)) end);

    return jsonb_build_object('ok', true, 'resumo', case when p_acao = 'etiqueta_add' then '✓ etiqueta ' || lab || ' posta' else '✓ etiqueta ' || lab || ' tirada' end);

  end if;

  raise exception 'Ação desconhecida: %', p_acao;

end;

$function$;

-- ───────────────────────── 2. OSAB ─────────────────────────
CREATE OR REPLACE FUNCTION public.aplicar_osab(p_importacao_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  imp         public.importacoes%rowtype;
  r           record;
  v_concl     boolean;
  v_cancel    boolean;
  v_risco     boolean;
  v_pcod      text;
  v_pdesc     text;
  v_novo      text;
  v_mudou     boolean;
  n_atual     int := 0;
  n_status    int := 0;
  n_saidas    int := 0;
  n_pend      int := 0;
  n_inval     int := 0;
  n_sem       int := 0;
  sem         jsonb;
  v_resumo    jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice aplicam importação.' using errcode = '42501';
  end if;

  select * into imp from public.importacoes where id = p_importacao_id for update;
  if not found then
    raise exception 'Importação % não encontrada.', p_importacao_id using errcode = 'P0001';
  end if;
  if imp.tipo <> 'osab' then
    raise exception 'Importação % não é OSAB.', p_importacao_id using errcode = 'P0001';
  end if;
  if imp.aplicado_em is not null then
    raise exception 'Esta importação já foi aplicada em %.', imp.aplicado_em using errcode = 'P0001';
  end if;

  -- Wipe-and-replace: o snapshot passa a ser só o arquivo atual.
  delete from public.nio_osab where importacao_id is distinct from p_importacao_id;

  for r in
    select o.*,
           v.id                        as venda_id,
           v.status                    as v_status,
           v.nio_situacao              as v_situacao,
           v.nio_pendencia_cod         as v_pcod,
           v.nio_pendencia_desc        as v_pdesc,
           v.nio_venda_valida          as v_valida
    from public.nio_osab o
    join public.vendas v on v.nio_pedido = o.pedido
    where o.importacao_id = p_importacao_id
  loop
    n_atual  := n_atual + 1;
    v_concl  := r.situacao = 'Concluído' and r.venda_valida is true;
    v_cancel := public.osab_cancelada(r.situacao);
    v_risco  := public.osab_risco(r.venda_valida, r.desc_pendencia, concat_ws(' ', r.motivo_cancelamento, r.submotivo_cancelamento));

    -- Pendência: vazio no OSAB = mantém; OK / 00 / N/A = resolvida; resto = pendência da Nio.
    if coalesce(btrim(r.cod_pendencia), '') = '' and coalesce(btrim(r.desc_pendencia), '') = '' then
      v_pcod := r.v_pcod;
      v_pdesc := r.v_pdesc;
    elsif upper(btrim(coalesce(r.desc_pendencia, ''))) in ('OK', 'N/A') or btrim(coalesce(r.cod_pendencia, '')) in ('0', '00') then
      v_pcod := null;
      v_pdesc := null;
    else
      v_pcod := nullif(btrim(r.cod_pendencia), '');
      v_pdesc := nullif(btrim(r.desc_pendencia), '');
    end if;

    update public.vendas set
      nio_situacao             = coalesce(nullif(btrim(r.situacao), ''), nio_situacao),
      nio_pendencia_cod        = v_pcod,
      nio_pendencia_desc       = v_pdesc,
      nio_venda_valida         = coalesce(r.venda_valida, nio_venda_valida),
      instalacao_agendada_para = coalesce(instalacao_agendada_para, r.data_agendamento),
      instalado_em             = case when v_concl then coalesce(r.data_fechamento, instalado_em) else instalado_em end,   -- 0153: a data da Nio vence a hora da leitura
      ativado_em               = case when v_concl then coalesce(r.data_fechamento, ativado_em) else ativado_em end,
      nio_osab_em              = now()
    where id = r.venda_id;

    -- Status: só avança. Concluído/válida leva 2 → 3 → 4; cancelamento leva 1–2 → saída.
    v_novo := null;
    if v_concl and r.v_status in ('1_vendido', '2_aguardando_instalacao', '3_instalado') then   -- 0153: OS aberta sem agendamento no NIOGEN também avança
      if r.v_status in ('1_vendido', '2_aguardando_instalacao') then
        update public.vendas set status = '3_instalado' where id = r.venda_id;
      end if;
      update public.vendas set status = '4_ativo_provisorio' where id = r.venda_id;
      v_novo := '4_ativo_provisorio';
    elsif v_cancel and r.v_status in ('1_vendido', '2_aguardando_instalacao') then
      update public.vendas set
        status = 'saida',
        motivo_saida = 'Nio: ' || coalesce(nullif(btrim(r.motivo_cancelamento), ''), r.situacao)
                       || coalesce(' · ' || nullif(btrim(r.submotivo_cancelamento), ''), '')
      where id = r.venda_id;
      v_novo := 'saida';
      n_saidas := n_saidas + 1;
    end if;
    if v_novo is not null then n_status := n_status + 1; end if;
    if v_novo is null and v_pcod is not null and r.v_status in ('1_vendido', '2_aguardando_instalacao') then
      n_pend := n_pend + 1;
    end if;
    if v_risco then n_inval := n_inval + 1; end if;

    -- Evento só quando algo mudou (reimportar o mesmo arquivo não enche a linha do tempo).
    v_mudou := v_novo is not null
            or r.situacao is distinct from r.v_situacao
            or v_pcod is distinct from r.v_pcod
            or r.venda_valida is distinct from r.v_valida;
    if v_mudou then
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (r.venda_id, 'osab', jsonb_strip_nulls(jsonb_build_object(
        'situacao', r.situacao, 'pendencia_cod', v_pcod, 'pendencia_desc', v_pdesc, 'venda_valida', r.venda_valida,
        'de', case when v_novo is not null then r.v_status end, 'para', v_novo,
        'dt_ref', r.dt_ref, 'importacao_id', p_importacao_id)), auth.uid());
      if v_risco then
        insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
        values (r.venda_id, 'osab_venda_invalida', jsonb_strip_nulls(jsonb_build_object(
          'venda_valida', r.venda_valida, 'pendencia_desc', r.desc_pendencia,
          'motivo', nullif(concat_ws(' · ', r.motivo_cancelamento, r.submotivo_cancelamento), ''),
          'importacao_id', p_importacao_id)), auth.uid());
      end if;
    end if;
  end loop;

  -- Pedidos que a Nio enxerga e o NIOGEN não.
  select count(*), coalesce(jsonb_agg(s.pedido order by s.pedido) filter (where s.n <= 1000), '[]'::jsonb)
    into n_sem, sem
  from (
    select o.pedido, row_number() over (order by o.pedido) as n
    from public.nio_osab o
    where o.importacao_id = p_importacao_id
      and not exists (select 1 from public.vendas v where v.nio_pedido = o.pedido)
  ) s;

  v_resumo := coalesce(imp.resumo, '{}'::jsonb) || jsonb_build_object(
    'atualizadas', n_atual, 'mudaram_status', n_status, 'saidas', n_saidas, 'pendencias', n_pend,
    'invalidas', n_inval, 'sem_venda', n_sem, 'sem_venda_pedidos', sem);

  update public.importacoes set
    aplicadas   = n_atual,
    ignoradas   = coalesce(ignoradas, 0) + n_sem,
    resumo      = v_resumo,
    aplicado_em = now()
  where id = p_importacao_id;

  return v_resumo;
end;
$function$;

-- ───────────────────────── 3. relógio das 4 h ─────────────────────────
create or replace view public.v_funil as
 SELECT v.id,
    v.criado_em,
    v.criado_por,
    v.status,
    v.motivo_saida,
    v.interesse_futuro_em,
    v.origem,
    v.origem_ref,
    v.cliente_nome,
    v.cliente_cpf_cnpj,
    v.cliente_whatsapp,
    v.cliente_email,
    v.segmento,
    v.cep,
    v.logradouro,
    v.numero,
    v.complemento,
    v.bairro,
    v.cidade,
    v.uf,
    v.plano_id,
    v.forma_pagamento,
    v.vencimento_dia,
    v.comissao_prevista,
    v.comissao_paga,
    v.ciclo_pago,
    v.estorno_previsto,
    v.nio_pedido,
    v.nio_contrato,
    v.nio_situacao,
    v.nio_pendencia_cod,
    v.nio_pendencia_desc,
    v.biometria_status,
    v.biometria_em,
    v.vendido_em,
    v.agendamento_registrado_em,
    v.instalacao_agendada_para,
    v.instalado_em,
    v.ativado_em,
    v.docs_entregues_em,
    v.vendedor_id,
    v.trava_cobertura,
    v.trava_area,
    v.trava_sem_produto_ativo,
    v.trava_sem_cancelamento_30d,
    v.trava_cpf_valido,
    v.trava_contato_confirmado,
    v.nio_osab_em,
    v.nio_venda_valida,
    v.valor_mensal,
    v.comissao_nominal,
    v.comissao_adicionais,
    v.bonus_transicao_previsto,
    v.bonus_nmei_previsto,
    v.bonus_m10_potencial,
    v.primeiro_vencimento,
    v.dfv_viabilidade,
    v.dfv_consultado_em,
    v.dfv_consultado_por,
    v.dfv_faixa_credito,
    v.dfv_classificacao,
    v.dfv_hp_livre,
    v.dfv_hcs,
    v.dfv_dispensado,
    v.dfv_dispensa_motivo,
    v.dfv_origem,
    v.dfv_resultado,
    v.dfv_particao,
    p.nome AS plano_nome,
    p.familia AS plano_familia,
    p.velocidade AS plano_velocidade,
    p.preco AS plano_preco,
    p.codigo AS plano_codigo,
    p.portfolio AS plano_portfolio,
    p.variante AS plano_variante,
    p.cluster AS plano_cluster,
    p.preco_cartao AS plano_preco_cartao,
    p.taxa_a_vista AS plano_taxa_a_vista,
    p.isencao_meses AS plano_isencao_meses,
    u.nome AS vendedor_nome,
        CASE
            WHEN v.status = '0_qualificado'::text AND v.biometria_status = 'validada'::text THEN round(EXTRACT(epoch FROM now() - v.biometria_validada_em) / 3600::numeric, 2)
            WHEN v.status = '1_vendido'::text AND v.agendamento_registrado_em IS NULL THEN round(EXTRACT(epoch FROM now() - GREATEST(v.biometria_validada_em, v.vendido_em)) / 3600::numeric, 2)
            ELSE NULL::numeric
        END AS horas_sem_agendamento,
        CASE
            WHEN v.status = '0_qualificado'::text AND COALESCE(btrim(v.nio_pedido), ''::text) <> ''::text AND v.biometria_status IS DISTINCT FROM 'validada'::text THEN round(EXTRACT(epoch FROM now() - COALESCE(v.biometria_link_enviado_em, v.nio_pedido_em, v.criado_em)) / 86400::numeric, 2)
            ELSE NULL::numeric
        END AS dias_esperando_biometria,
    v.instalado_em + '15 days'::interval AS docs_prazo_em,
    COALESCE(v.ativado_em, v.instalado_em) + '30 days'::interval AS firme_em,
    (v.dfv_viabilidade = ANY (ARRAY['viavel'::text, 'viavel_predio'::text])) AND v.dfv_consultado_em >= (now() - '7 days'::interval) AS dfv_ok,
        CASE
            WHEN v.dfv_consultado_em IS NOT NULL THEN floor(EXTRACT(epoch FROM now() - v.dfv_consultado_em) / 86400::numeric)::integer
            ELSE NULL::integer
        END AS dfv_dias,
    COALESCE(v.ativado_em, v.instalado_em) + '180 days'::interval AS downgrade_ate,
    v.nio_viab_resultado,
    v.nio_viab_velocidade,
    v.nio_viab_interesse_id,
    v.nio_viab_endereco_id,
    v.nio_viab_em,
    v.nio_viab_origem,
    v.credito_resultado,
    v.credito_em,
    v.biometria_link,
    v.biometria_link_enviado_em,
    v.biometria_validada_em,
    v.instalacao_preferencia,
    v.instalacao_turno,
    v.nio_viab_resultado = 'viavel'::text AND v.nio_viab_em >= (now() - '7 days'::interval) AS nio_viab_ok,
    v.nio_viab_resultado = 'viavel'::text AND v.nio_viab_em >= (now() - '7 days'::interval) OR (v.dfv_viabilidade = ANY (ARRAY['viavel'::text, 'viavel_predio'::text])) AND v.dfv_consultado_em >= (now() - '7 days'::interval) OR COALESCE(v.dfv_dispensado, false) AS viab_ok,
        CASE
            WHEN (v.status = ANY (ARRAY['0_qualificado'::text, '1_vendido'::text])) AND (v.biometria_status = ANY (ARRAY['pendente'::text, 'com_risco'::text])) AND v.biometria_link_enviado_em IS NOT NULL THEN round(EXTRACT(epoch FROM now() - v.biometria_link_enviado_em) / 3600::numeric, 1)
            ELSE NULL::numeric
        END AS horas_biometria_pendente,
        CASE
            WHEN v.status = '0_qualificado'::text AND v.credito_resultado = 'pendente'::text AND v.credito_em IS NOT NULL THEN round(EXTRACT(epoch FROM now() - v.credito_em) / 3600::numeric, 1)
            ELSE NULL::numeric
        END AS horas_credito_pendente,
    COALESCE(v.biometria_validada_em, v.vendido_em) AS agendar_desde,
    v.nio_viab_endereco_portal,
    v.parceiro_id,
    pa.nome AS parceiro_nome,
    v.conferencia_status,
    v.conferencia_motivo,
    v.conferencia_prazo_ate,
    pe.id AS pend_id,
    pe.motivo AS pend_motivo,
    pm.nome AS pend_motivo_nome,
    pe.descricao AS pend_descricao,
    pe.quem_destrava AS pend_quem,
    pe.aberta_em AS pend_desde,
    pe.revisar_em AS pend_revisar_em,
    pe.revisoes AS pend_revisoes,
    pm.saida_sugerida AS pend_saida_sugerida,
    v.nio_os,
    v.nio_os_em,
    jornada_etapa(v.status, v.nio_pedido, v.credito_resultado) AS jornada_etapa
   FROM vendas v
     LEFT JOIN config_planos p ON p.id = v.plano_id
     LEFT JOIN usuarios u ON u.id = v.vendedor_id
     LEFT JOIN parceiros pa ON pa.id = v.parceiro_id
     LEFT JOIN venda_pendencias pe ON pe.venda_id = v.id AND pe.encerrada_em IS NULL
     LEFT JOIN config_motivos_pendencia pm ON pm.codigo = pe.motivo;

-- ───────────────────────── 4. mexida direto no Chatwoot ─────────────────────────
alter table public.mari_conversas drop constraint if exists mari_conversas_funil_alerta_check;
alter table public.mari_conversas add constraint mari_conversas_funil_alerta_check check (funil_alerta is null or funil_alerta in
  ('resolvida_fora_niogen', 'mensagem_fora_niogen', 'atribuida_fora_niogen', 'adiada_fora_niogen'));

create or replace function public._cw_mexida_fora()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.canal, '') <> 'whatsapp' or coalesce(new.telefone, '') like '5500000000%' then return new; end if;
  -- desfez: o selo some sozinho
  if new.funil_alerta = 'adiada_fora_niogen' and coalesce(new.chatwoot_status, 'open') = 'open' then
    new.funil_alerta := null; new.funil_alerta_em := null;
  elsif new.funil_alerta = 'atribuida_fora_niogen' and new.chatwoot_agente is null then
    new.funil_alerta := null; new.funil_alerta_em := null;
  end if;
  if new.funil_alerta is not null or coalesce(new.funil_destino, 'em_andamento') <> 'em_andamento' then return new; end if;
  -- adiada (snooze) sem ter saído de um botão do NIOGEN (Aguardar, Silenciar)
  if new.chatwoot_status = 'snoozed' and old.chatwoot_status is distinct from 'snoozed'
     and new.espera_ate is null and coalesce(new.quadro_encerrada_motivo, '') <> 'suporte_nio'
     and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = new.id and a.tipo = 'resolver'
                       and a.payload ->> 'status' = 'snoozed' and a.criada_em > now() - interval '6 hours') then
    new.funil_alerta := 'adiada_fora_niogen'; new.funil_alerta_em := now();
    insert into public.funil_eventos (conversa_id, tipo, para, detalhe)
    values (new.id, 'alerta', 'adiada_fora_niogen', 'adiada direto no Chatwoot');
  -- atribuída a uma pessoa sem ter saído do Assumir / da resposta pelo NIOGEN
  elsif new.chatwoot_agente is not null and new.chatwoot_agente is distinct from old.chatwoot_agente
     and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = new.id and a.tipo = 'atribuir'
                       and a.criada_em > now() - interval '6 hours') then
    new.funil_alerta := 'atribuida_fora_niogen'; new.funil_alerta_em := now();
    insert into public.funil_eventos (conversa_id, tipo, para, detalhe)
    values (new.id, 'alerta', 'atribuida_fora_niogen', 'atribuída direto no Chatwoot a ' || new.chatwoot_agente);
  end if;
  return new;
exception when others then
  return new;   -- o selo nunca derruba a gravação da conversa
end;
$$;
revoke all on function public._cw_mexida_fora() from public, anon, authenticated;
drop trigger if exists mari_conversas_cw_mexida_fora on public.mari_conversas;
create trigger mari_conversas_cw_mexida_fora before update of chatwoot_status, chatwoot_agente on public.mari_conversas
  for each row execute function public._cw_mexida_fora();

-- ───────────────────────── 5. lista "Conferir" da Live ─────────────────────────
insert into public.config_regras (chave, valor, descricao) values
  ('envelhecimento_dono_horas', '24'::jsonb,
   'Live › Conferir: conversa em andamento com dono (pessoa ou time) e sem nenhuma fala há mais de N horas aparece como parada. 0153.')
on conflict (chave) do nothing;

create or replace function public.live_conferir()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_horas numeric := coalesce((select (valor #>> '{}')::numeric from public.config_regras where chave = 'envelhecimento_dono_horas'), 24);
  v_docs  int := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'prazo_docs_dias'), 15);
  r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return '[]'::jsonb; end if;
  with nomes as (
    select c.id, c.venda_id,
           coalesce(nullif(btrim(c.dados ->> 'nome'), ''), nullif(btrim(c.nome_contato), ''), 'Contato') as nome,
           c.chatwoot_agente, c.funil_alerta, c.funil_alerta_em
      from public.mari_conversas c
     where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
  ),
  itens as (
    -- (a) ação do Chatwoot que falhou 3 vezes e não foi refeita depois
    select 'acao_falhou' as tipo, a.id::text as chave, a.conversa_id, a.venda_id, n.nome, a.criada_em as desde, 1 as ordem,
           format('O Chatwoot não obedeceu: %s%s', case a.tipo when 'resolver' then 'resolver / reabrir' when 'etiquetas' then 'etiqueta'
                    when 'atribuir' then 'atribuir' when 'desatribuir' then 'tirar a atribuição' when 'nota' then 'nota privada'
                    when 'mensagem' then 'mensagem ao cliente' else a.tipo end,
                  coalesce(' — ' || left(a.erro, 120), '')) as texto
      from public.chatwoot_acoes a
      left join nomes n on n.id = a.conversa_id
     where a.status = 'erro' and a.criada_em > now() - interval '7 days'
       and not exists (select 1 from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.tipo = a.tipo
                         and b.status = 'feita' and b.criada_em > a.criada_em)
    union all
    -- (b) conversa mexida direto no Chatwoot
    select 'fora_niogen', n.id::text, n.id, n.venda_id, n.nome, n.funil_alerta_em, 2,
           case n.funil_alerta
             when 'resolvida_fora_niogen' then 'Resolvida direto no Chatwoot, sem destino — registre a Saída (ou reabra)'
             when 'mensagem_fora_niogen' then 'Respondida direto no Chatwoot — responda pelo NIOGEN para a venda andar'
             when 'atribuida_fora_niogen' then 'Atribuída direto no Chatwoot a ' || coalesce(n.chatwoot_agente, 'alguém') || ' — a Mari calou; assuma pelo NIOGEN ou devolva para a Mari'
             else 'Adiada direto no Chatwoot — some da fila sem data de volta; use ⏸ Aguardar no NIOGEN' end
      from nomes n where n.funil_alerta is not null
    union all
    -- (c) conversa em andamento com dono e sem nenhuma fala há mais de N horas
    select 'dono_parado', c.id::text, c.id, c.venda_id, n.nome, u.ult, 3,
           format('Com %s e parada há %s — retomar, devolver para a Mari ou registrar a Saída',
                  coalesce(c.chatwoot_agente, 'o time'),
                  case when now() - u.ult >= interval '48 hours' then floor(extract(epoch from now() - u.ult) / 86400)::int || ' dias'
                       else floor(extract(epoch from now() - u.ult) / 3600)::int || ' h' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
      left join public.vendas v on v.id = c.venda_id
      cross join lateral (select max(t.created_at) as ult from public.mari_turnos t
                           where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano')) u
     where coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'
       and (c.humano_atribuido or c.time_atribuido or c.chatwoot_agente is not null)
       and not coalesce(c.nao_contatar, false)
       and c.quadro_encerrada_motivo is null
       and (c.espera_ate is null or c.espera_ate <= now())
       and coalesce(c.chatwoot_status, 'open') <> 'snoozed'
       and (v.id is null or v.status in ('0_qualificado', '1_vendido'))
       and not exists (select 1 from public.venda_pendencias vp where vp.venda_id = c.venda_id and vp.encerrada_em is null)
       and u.ult is not null and u.ult < now() - make_interval(mins => (v_horas * 60)::int)
    union all
    -- (d) documentos à Nio: 15 dias depois da instalação
    select 'docs_prazo', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), v.instalado_em, 4,
           case when v.instalado_em + make_interval(days => v_docs) < now()
                  then format('Documentos à Nio ATRASADOS — o prazo era %s', to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'))
                else format('Documentos à Nio até %s (%s dias depois da instalação)',
                            to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'), v_docs) end
      from public.vendas v
     where v.status in ('3_instalado', '4_ativo_provisorio') and v.instalado_em is not null and v.docs_entregues_em is null
       and v.instalado_em > now() - interval '90 days'
  )
  select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'chave', chave, 'conversa_id', conversa_id, 'venda_id', venda_id,
                                               'nome', nome, 'desde', desde, 'texto', texto) order by ordem, desde), '[]'::jsonb)
    into r from itens;
  return r;
end;
$$;
revoke all on function public.live_conferir() from public, anon;
grant execute on function public.live_conferir() to authenticated;

create or replace function public.chatwoot_acao_retentar(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  update public.chatwoot_acoes set status = 'pendente', tentativas = 0, erro = null, executar_apos = now(), pega_em = null
   where id = p_id and status = 'erro';
  if not found then raise exception 'Essa ação não está em erro.'; end if;
  return jsonb_build_object('ok', true, 'resumo', '✓ de volta na fila — o Chatwoot recebe em até 1 minuto');
end;
$$;
revoke all on function public.chatwoot_acao_retentar(bigint) from public, anon;
grant execute on function public.chatwoot_acao_retentar(bigint) to authenticated;

create or replace function public.chatwoot_acao_dispensar(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  update public.chatwoot_acoes set status = 'cancelada' where id = p_id and status = 'erro';
  if not found then raise exception 'Essa ação não está em erro.'; end if;
  return jsonb_build_object('ok', true, 'resumo', '✓ dispensada');
end;
$$;
revoke all on function public.chatwoot_acao_dispensar(bigint) from public, anon;
grant execute on function public.chatwoot_acao_dispensar(bigint) to authenticated;

-- "Visto" só para atribuída / adiada fora do NIOGEN (resolvida e respondida somem pelo caminho de sempre: Saída ou resposta).
create or replace function public.conversa_alerta_visto(p_conversa uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  update public.mari_conversas set funil_alerta = null, funil_alerta_em = null
   where id = p_conversa and funil_alerta in ('atribuida_fora_niogen', 'adiada_fora_niogen');
  insert into public.funil_eventos (conversa_id, tipo, para, detalhe, por) values (p_conversa, 'alerta', 'visto', 'selo dispensado na Live', auth.uid());
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.conversa_alerta_visto(uuid) from public, anon;
grant execute on function public.conversa_alerta_visto(uuid) to authenticated;
