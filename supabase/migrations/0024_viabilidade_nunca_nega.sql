-- NIOGEN | supabase/migrations/0024_viabilidade_nunca_nega.sql | 05/11/2026 — Claude Code (prompt nº 15, adendo do Ricardo 10h05)
-- Regra absoluta: a viabilidade oficial do portal NUNCA nega venda — só muda a nota do handoff. Um "não viável" quase
-- sempre é erro de endereço (CEP digitado errado, rua com outro nome no cadastro da Nio, número que não casa).
--   1. nio_viab_resultado ganha 'nao_encontrado' (vendas, mari_conversas, nio_viab_log).
--   2. nio_viab_log ganha tentativas (jsonb — a cascata CEP+nº → CEP sem nº → rua+cidade → rua do ViaCEP × rua do
--      cliente) e endereco_portal (como a Nio cadastrou); vendas/mari_conversas ganham nio_viab_endereco_portal.
--   3. mari_handoff: sai a recusa por 'sem_viabilidade' (estava na 0023); toda viabilidade ≠ viável vira a nota
--      "portal: <resultado> — conferir manualmente (variações de CEP/rua/número) antes de abrir o pedido".
-- A trava 0 → 1 do NIOGEN não muda: quem decide sem cobertura é o humano no portal, antes de registrar a venda.

alter table public.vendas drop constraint if exists vendas_nio_viab_resultado_check;
alter table public.vendas add constraint vendas_nio_viab_resultado_check
  check (nio_viab_resultado in ('viavel', 'sem_viabilidade', 'nao_encontrado', 'posse', 'indisponivel'));
alter table public.mari_conversas drop constraint if exists mari_conversas_nio_viab_resultado_check;
alter table public.mari_conversas add constraint mari_conversas_nio_viab_resultado_check
  check (nio_viab_resultado in ('viavel', 'sem_viabilidade', 'nao_encontrado', 'posse', 'indisponivel'));
alter table public.nio_viab_log drop constraint if exists nio_viab_log_resultado_check;
alter table public.nio_viab_log add constraint nio_viab_log_resultado_check
  check (resultado in ('viavel', 'sem_viabilidade', 'nao_encontrado', 'posse', 'indisponivel'));

alter table public.nio_viab_log
  add column if not exists tentativas      jsonb,   -- [{passo, entrada, interesse_id, achou, status_final, ms}]
  add column if not exists endereco_portal jsonb;   -- {logradouro, bairro, cidade, uf, cep} como a Nio cadastrou
alter table public.vendas         add column if not exists nio_viab_endereco_portal text;
alter table public.mari_conversas add column if not exists nio_viab_endereco_portal text;

comment on column public.vendas.nio_viab_resultado is
  'Viabilidade oficial do portal PAP (nível A): viavel | sem_viabilidade | nao_encontrado | posse | indisponivel. '
  'NUNCA nega venda na Mari (05/11 10h05): só muda a nota do handoff; quem decide é o humano no portal.';

-- mari_handoff (0023 + adendo): sem recusa por viabilidade; nota padrão para todo resultado ≠ viável.
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

  v_motivo := case
    when coalesce(c.elegibilidade, '') <> 'ok' then 'elegibilidade não confirmada (' || coalesce(c.elegibilidade, 'vazia') || ')'
    when v_cluster is null then 'fora da área de atuação (' || coalesce(c.cidade, 'cidade desconhecida') || ')'
    when v_plano.id is null then 'plano não escolhido'
    when coalesce(btrim(d ->> 'nome'), '') = '' then 'nome do cliente ausente'
    when c.cep is null or c.numero is null then 'endereço incompleto'
    when exists (select 1 from public.vendas v where v.status <> 'saida'
                   and ((v_cpf <> '' and regexp_replace(coalesce(v.cliente_cpf_cnpj, ''), '\D', '', 'g') = v_cpf)
                     or (regexp_replace(coalesce(v.cep, ''), '\D', '', 'g') = c.cep
                         and lower(btrim(coalesce(v.numero, ''))) = lower(btrim(c.numero))
                         and lower(btrim(coalesce(v.complemento, ''))) = lower(btrim(coalesce(c.complemento, ''))))))
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
    values (p_conversa, 'mari_handoff', 'venda não criada: ' || v_motivo, jsonb_build_object('lead', l, 'dados', d));
    return jsonb_build_object('ok', false, 'venda_id', null, 'motivo_recusa', v_motivo);
  end if;

  return jsonb_build_object('ok', true, 'venda_id', v_venda);
end;
$$;

-- v_funil: endereço como a Nio cadastrou (colunas novas sempre no fim).
create or replace view public.v_funil with (security_invoker = true) as
select
    v.id, v.criado_em, v.criado_por, v.status, v.motivo_saida, v.interesse_futuro_em, v.origem, v.origem_ref,
    v.cliente_nome, v.cliente_cpf_cnpj, v.cliente_whatsapp, v.cliente_email, v.segmento,
    v.cep, v.logradouro, v.numero, v.complemento, v.bairro, v.cidade, v.uf, v.plano_id, v.forma_pagamento,
    v.vencimento_dia, v.comissao_prevista, v.comissao_paga, v.ciclo_pago, v.estorno_previsto,
    v.nio_pedido, v.nio_contrato, v.nio_situacao, v.nio_pendencia_cod, v.nio_pendencia_desc,
    v.biometria_status, v.biometria_em, v.vendido_em, v.agendamento_registrado_em, v.instalacao_agendada_para,
    v.instalado_em, v.ativado_em, v.docs_entregues_em, v.vendedor_id,
    v.trava_cobertura, v.trava_area, v.trava_sem_produto_ativo, v.trava_sem_cancelamento_30d, v.trava_cpf_valido,
    v.trava_contato_confirmado, v.nio_osab_em, v.nio_venda_valida, v.valor_mensal, v.comissao_nominal,
    v.comissao_adicionais, v.bonus_transicao_previsto, v.bonus_nmei_previsto, v.bonus_m10_potencial, v.primeiro_vencimento,
    v.dfv_viabilidade, v.dfv_consultado_em, v.dfv_consultado_por, v.dfv_faixa_credito, v.dfv_classificacao,
    v.dfv_hp_livre, v.dfv_hcs, v.dfv_dispensado, v.dfv_dispensa_motivo, v.dfv_origem, v.dfv_resultado, v.dfv_particao,
    p.nome as plano_nome, p.familia as plano_familia, p.velocidade as plano_velocidade, p.preco as plano_preco,
    p.codigo as plano_codigo, p.portfolio as plano_portfolio, p.variante as plano_variante, p.cluster as plano_cluster,
    p.preco_cartao as plano_preco_cartao, p.taxa_a_vista as plano_taxa_a_vista, p.isencao_meses as plano_isencao_meses,
    u.nome as vendedor_nome,
    case when v.status = '1_vendido' and v.agendamento_registrado_em is null and v.vendido_em is not null
         then round(extract(epoch from now() - v.vendido_em) / 3600, 2) end as horas_sem_agendamento,
    case when v.status = '0_qualificado' and v.biometria_status is distinct from 'validada'
         then round(extract(epoch from now() - v.criado_em) / 86400, 2) end as dias_esperando_biometria,
    v.instalado_em + interval '15 days' as docs_prazo_em,
    coalesce(v.ativado_em, v.instalado_em) + interval '30 days' as firme_em,
    (v.dfv_viabilidade in ('viavel', 'viavel_predio') and v.dfv_consultado_em >= now() - interval '7 days') as dfv_ok,
    case when v.dfv_consultado_em is not null then floor(extract(epoch from now() - v.dfv_consultado_em) / 86400)::int end as dfv_dias,
    coalesce(v.ativado_em, v.instalado_em) + interval '180 days' as downgrade_ate,
    v.nio_viab_resultado, v.nio_viab_velocidade, v.nio_viab_interesse_id, v.nio_viab_endereco_id, v.nio_viab_em, v.nio_viab_origem,
    v.credito_resultado, v.credito_em, v.biometria_link, v.biometria_link_enviado_em, v.biometria_validada_em,
    v.instalacao_preferencia, v.instalacao_turno,
    (v.nio_viab_resultado = 'viavel' and v.nio_viab_em >= now() - interval '7 days') as nio_viab_ok,
    ((v.nio_viab_resultado = 'viavel' and v.nio_viab_em >= now() - interval '7 days')
      or (v.dfv_viabilidade in ('viavel', 'viavel_predio') and v.dfv_consultado_em >= now() - interval '7 days')
      or coalesce(v.dfv_dispensado, false)) as viab_ok,
    case when v.status = '0_qualificado' and v.biometria_status in ('pendente', 'com_risco') and v.biometria_link_enviado_em is not null
         then round(extract(epoch from now() - v.biometria_link_enviado_em) / 3600, 1) end as horas_biometria_pendente,
    case when v.status = '0_qualificado' and v.credito_resultado = 'pendente' and v.credito_em is not null
         then round(extract(epoch from now() - v.credito_em) / 3600, 1) end as horas_credito_pendente,
    greatest(v.biometria_validada_em, v.vendido_em) as agendar_desde,
    v.nio_viab_endereco_portal
  from public.vendas v
  left join public.config_planos p on p.id = v.plano_id
  left join public.usuarios u on u.id = v.vendedor_id;
