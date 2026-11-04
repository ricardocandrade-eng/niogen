-- NIOGEN | supabase/migrations/0019_mari_handoff_briefing.sql | 04/11/2026 — Claude Code (pendência 31 do Diário)
-- O briefing para o humano só era gravado quando o handoff era "dados_completos" (ia para vendas.observacoes).
-- Nos outros motivos (pediu humano, objeção, urgência, mais de um decisor…) — justamente os que o humano precisa
-- ler antes de responder — ele se perdia, e a tela Mari mostrava "Sem briefing gravado".
--  * mari_conversas.handoff_briefing (nova, opcional)
--  * mari_handoff: idêntica à da 0013 (conferida com pg_get_functiondef em 04/11) + UMA linha que grava o briefing
--    de p_lead.briefing em qualquer motivo. Nada muda na criação da venda, nas travas ou no retorno da função.
--  * v_mari_conversas: + handoff_briefing no fim (CREATE OR REPLACE, colunas antigas intactas).
-- O n8n (mari_principal) não muda: o nó 9 · Handoff já envia p_lead.briefing. Idempotente.

alter table public.mari_conversas add column if not exists handoff_briefing text;
comment on column public.mari_conversas.handoff_briefing is 'Briefing da Mari para o humano no handoff (qualquer motivo). Desde a 0019.';

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
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('ok', false, 'motivo_recusa', 'conversa inexistente'); end if;

  -- Guard-rail 10: não repetir handoff.
  if c.status <> 'ativo' then
    return jsonb_build_object('ok', true, 'repetido', true, 'venda_id', c.venda_id);
  end if;

  d := c.dados || coalesce(l -> 'dados', '{}'::jsonb);

  update public.mari_conversas set
    status = 'handoff_realizado', etapa = 'handoff', handoff_motivo = p_motivo, handoff_em = now(),
    handoff_briefing = coalesce(nullif(btrim(l ->> 'briefing'), ''), handoff_briefing),   -- 0019: todo motivo
    dados = d, processando_ate = null,
    nao_contatar = nao_contatar or p_motivo = 'recusa_compra',
    agendamento_retorno = coalesce((l ->> 'agendamento_retorno')::timestamptz, agendamento_retorno)
  where id = p_conversa
  returning * into c;

  if p_motivo <> 'dados_completos' then
    return jsonb_build_object('ok', true, 'venda_id', null);
  end if;

  -- Pré-condições da venda (ordem: elegibilidade, área, plano, dados mínimos, duplicidade).
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
      'Visita: ' || coalesce(c.visita_preferencia, l ->> 'visita_preferencia', '?'),
      'DFV: ' || case coalesce(c.dfv_resultado, '')
                   when 'viavel' then 'viável'
                   when 'viavel_predio' then 'viável (prédio) — conferir unidade'
                   when 'endereco_ocupado' then 'indica Nio ativo no endereço — confirmar com o cliente e no APP antes da visita'
                   else 'conferir manualmente antes da visita' end,
      nullif(v_brief, ''));

    begin
      insert into public.vendas (
        status, origem, origem_ref, cliente_nome, cliente_cpf_cnpj, cliente_whatsapp, cliente_email, segmento,
        cep, logradouro, numero, complemento, bairro, cidade, uf, plano_id, forma_pagamento,
        trava_area, trava_cpf_valido, trava_contato_confirmado, observacoes,
        dfv_viabilidade, dfv_resultado, dfv_hp_livre, dfv_hcs, dfv_faixa_credito, dfv_classificacao,
        dfv_particao, dfv_origem, dfv_consultado_em)
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
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then now() end)
      returning id into v_venda;

      insert into public.eventos_venda (venda_id, tipo, detalhe)
      values (v_venda, 'mari_handoff', jsonb_strip_nulls(jsonb_build_object(
        'conversa_id', c.id, 'motivo', p_motivo, 'canal', c.canal, 'briefing', nullif(v_brief, ''),
        'visita_preferencia', c.visita_preferencia, 'dfv_resultado', c.dfv_resultado)));

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

create or replace view public.v_mari_conversas
with (security_invoker = true) as
select
  c.id, c.telefone, c.nome_contato, c.canal, c.origem, c.status, c.etapa,
  c.cidade, c.uf, c.cluster, c.dentro_area, c.segmento, c.elegibilidade,
  c.plano_escolhido, p.nome as plano_nome, c.forma_pagamento, c.dfv_resultado,
  c.handoff_motivo, c.handoff_em, c.venda_id,
  c.created_at, c.updated_at, c.ultima_msg_lead_at,
  now() - c.created_at as idade,
  (select count(*) from public.mari_turnos t where t.conversa_id = c.id)::int as turnos,
  c.handoff_briefing
from public.mari_conversas c
left join public.config_planos p on p.codigo = c.plano_escolhido;

-- permissões iguais às da 0013 (create or replace mantém, reafirmado aqui)
revoke execute on function public.mari_handoff(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.mari_handoff(uuid, text, jsonb) to service_role;
revoke all on public.v_mari_conversas from anon;
grant select on public.v_mari_conversas to authenticated;
