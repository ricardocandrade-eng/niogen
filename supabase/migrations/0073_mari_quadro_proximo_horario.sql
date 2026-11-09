-- NIOGEN | supabase/migrations/0073_mari_quadro_proximo_horario.sql | 09/11/2026 — Claude Code (Prompt_mari_quadro_termometro_081126_2115)
-- Por quê: a cadência devolve proximo_em "cru" (ex.: L15 às 00h52) e o card mostrava toque fora do horário do contrato.
-- O quê: v_mari_quadro ganha, NO FIM, proximo_toque_em = mari_proximo_horario(proximo_em, cidade) (seg–sex 9–21, sáb 10–16,
-- nunca domingo/feriado). Resto da view igual à 0072.

create or replace view public.v_mari_quadro with (security_invoker = true) as
with base as (
  select c.*, to_jsonb(c) as j,
         v.status as venda_status, v.motivo_saida as venda_motivo_saida,
         (select max(t.created_at) from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano') as ult_humano
    from public.mari_conversas c
    left join public.vendas v on v.id = c.venda_id
),
ch as (
  select b.*,
    case
      when b.quadro_encerrada_em is not null
           and (b.ultima_msg_lead_at is null or b.ultima_msg_lead_at <= b.quadro_encerrada_em) then 'encerrada'
      when b.status in ('encerrado_humano', 'encerrado_ia') then 'encerrada'
      when b.nao_contatar then 'encerrada'
      when b.venda_status = 'saida' then 'encerrada'
      when b.status = 'handoff_realizado'
           and b.handoff_motivo in ('recusa_compra', 'sem_cobertura', 'fora_de_area', 'ja_cliente_nio', 'sem_contato') then 'encerrada'
      when b.status = 'handoff_realizado' and b.handoff_motivo = 'dados_completos' then 'handoff:dados_completos'
      when b.status = 'handoff_realizado' or b.humano_atribuido then 'humano'
      else coalesce(b.etapa, 'abertura')
    end as etapa_chave
  from base b
)
select
  ch.id,
  ch.created_at,
  ch.canal,
  (ch.canal = 'teste' or coalesce(ch.telefone, '') like '5500000000%') as teste,
  coalesce(nullif(btrim(ch.dados ->> 'nome'), ''), ch.nome_contato) as nome,
  ch.cidade,
  ch.cluster,
  coalesce(ch.segmento, 'varejo') as segmento,
  ch.origem,
  an.ad_nome, an.adset_nome, an.campanha_nome,
  ch.plano_escolhido,
  p.nome_curto as plano_nome,
  ch.status,
  ch.etapa,
  ch.etapa_chave,
  (select k.codigo from public.config_mari_colunas k
    where k.ativo and ch.etapa_chave = any (k.etapas) order by k.ordem limit 1) as coluna,
  case when ch.etapa_chave <> 'encerrada' then null
       when ch.quadro_encerrada_motivo is not null then ch.quadro_encerrada_motivo
       when ch.nao_contatar then 'nao_contatar'
       when ch.handoff_motivo = 'ja_cliente_nio' or ch.elegibilidade in ('ja_cliente', 'cancelou_30d') then 'ja_cliente'
       when ch.handoff_motivo in ('fora_de_area', 'sem_cobertura') or ch.dentro_area is false then 'fora_area'
       when ch.venda_id is not null and coalesce(ch.venda_status, '') <> 'saida' then 'venda'
       when ch.status = 'encerrado_humano' then 'zerada'
       else 'perdida' end as encerrada_motivo,
  ch.venda_motivo_saida,
  case when ch.etapa_chave <> 'encerrada' then null
       when ch.quadro_encerrada_motivo is not null then coalesce(
         (select m ->> 'nome' from public.config_mari_colunas k, jsonb_array_elements(coalesce(k.motivos, '[]'::jsonb)) m
           where k.codigo = 'encerrada' and m ->> 'codigo' = ch.quadro_encerrada_motivo limit 1), ch.quadro_encerrada_motivo)
       when ch.venda_status = 'saida' then 'Venda em Saída' || coalesce(' · ' || ch.venda_motivo_saida, '')
       when ch.nao_contatar then 'Não contatar'
       when ch.handoff_motivo = 'ja_cliente_nio' or ch.elegibilidade in ('ja_cliente', 'cancelou_30d') then 'Já é cliente Nio'
       when ch.handoff_motivo in ('fora_de_area', 'sem_cobertura') or ch.dentro_area is false then 'Fora de área'
       when ch.venda_id is not null then 'Venda criada'
       when ch.status = 'encerrado_humano' then 'Memória zerada (#zerar)'
       when ch.handoff_motivo = 'recusa_compra' then 'Perdida · recusou'
       when ch.handoff_motivo = 'sem_contato' then 'Perdida · sem contato'
       else 'Perdida' end as encerrada_txt,
  -- vez: de quem é a próxima fala
  case
    when ch.etapa_chave = 'encerrada' then null
    when ch.status = 'handoff_realizado' or ch.humano_atribuido then
      case when ch.ult_humano is not null and ch.ult_humano >= coalesce(ch.ultima_msg_lead_at, '-infinity'::timestamptz)
           then 'cliente' else 'humano' end
    when ch.ultima_msg_lead_at is not null and ch.ultima_msg_lead_at > coalesce(ch.ultima_msg_mari_at, '-infinity'::timestamptz) then 'mari'
    else 'cliente' end as vez,
  case
    when ch.status = 'handoff_realizado' or ch.humano_atribuido then greatest(ch.ultima_msg_lead_at, ch.handoff_em)
    else ch.ultima_msg_lead_at end as vez_desde,
  greatest(ch.ultima_msg_lead_at, ch.ultima_msg_mari_at, ch.ult_humano, ch.created_at) as ultima_em,
  case greatest(ch.ultima_msg_lead_at, ch.ultima_msg_mari_at, ch.ult_humano)
    when ch.ultima_msg_lead_at then 'cliente' when ch.ult_humano then 'humano' when ch.ultima_msg_mari_at then 'mari' end as ultima_quem,
  ch.ultima_msg_lead_at + interval '24 hours' as janela_24h_fecha_em,
  k.proximo_passo, k.proximo_em, k.pode_enviar, k.bloqueio,
  coalesce(k.toques_hoje, tq.hoje, 0) as contatos_hoje,
  coalesce(k.toques_mes,  tq.mes,  0) as contatos_mes,
  array_remove(array[
    case when ch.nao_contatar then 'nao_contatar' end,
    case when exists (select 1 from public.mari_turnos t where t.conversa_id = ch.id and t.papel = 'lead'
                       and t.texto ~* '(descont|abaixa\w* (o |esse )?(pre[cç]o|valor)|mais barat|faz (um |por )?menos)') then 'desconto' end,
    case when exists (select 1 from public.mari_turnos t where t.conversa_id = ch.id and t.papel = 'lead'
                       and t.texto ~* '(reclama|sem internet|internet (caiu|parou|lenta|ruim|n[aã]o funciona)|t[eé]cnico n[aã]o (veio|apareceu)|j[aá] sou cliente)') then 'reclamacao_nio' end,
    case when exists (select 1 from public.mari_turnos t where t.conversa_id = ch.id and t.papel = 'lead'
                       and t.texto ~* '(n[aã]o (pedi|solicitei|autorizei)|como (vc|voc[eê]s?) (conseguiu|pegou|achou) meu|n[aã]o me (mande|chame|ligue))') then 'nao_pedi_contato' end,
    case when ch.handoff_motivo = 'urgencia_alta'
           or exists (select 1 from public.mari_turnos t where t.conversa_id = ch.id and t.tags ? 'sinal_urgencia') then 'urgencia' end
  ], null) as alertas,
  ch.venda_id,
  ch.venda_status,
  -- termômetro (só o estado de cada item — nunca o valor)
  coalesce(tm.itens_total, 0)     as itens_total,
  coalesce(tm.itens_coletados, 0) as itens_coletados,
  coalesce(tm.itens_validados, 0) as itens_validados,
  coalesce(tm.faltam, '{}')       as faltam,
  coalesce(tm.itens, '[]'::jsonb) as itens,
  tr.trava_cliente_nio, tr.trava_endereco_nio, tr.trava_viabilidade,
  ( coalesce(tm.itens_total, 0) > 0 and tm.itens_validados = tm.itens_total
    and tr.trava_cliente_nio = 'ok' and tr.trava_endereco_nio <> 'bloqueia' and tr.trava_viabilidade <> 'bloqueia'
    and ch.etapa_chave not in ('handoff:dados_completos', 'humano', 'encerrada') ) as pronto_handoff,
  ch.chatwoot_conversation_id,
  'dharma'::text as parceiro_id,
  -- 0073: quando o toque pode sair de fato (horário do contrato, domingo e feriado da cidade)
  case when k.proximo_em is not null then public.mari_proximo_horario(k.proximo_em, ch.cidade) end as proximo_toque_em
from ch
left join public.config_planos p on p.codigo = ch.plano_escolhido
left join lateral (
  select a.ad_nome, a.adset_nome, a.campanha_nome from public.v_mari_conversa_anuncio a
   where a.conversa_id = ch.id order by a.referral_em desc nulls last limit 1
) an on true
left join public.v_mari_cadencia k on k.conversa_id = ch.id
left join lateral public.mari_toques(ch.telefone, now()) tq on true
left join lateral (
  select count(*) filter (where x.obrigatorio)                              as itens_total,
         count(*) filter (where x.obrigatorio and x.estado <> 'vazio')      as itens_coletados,
         count(*) filter (where x.obrigatorio and x.estado = 'validado')    as itens_validados,
         array_agg(x.nome order by x.ordem) filter (where x.obrigatorio and x.estado <> 'validado') as faltam,
         jsonb_agg(jsonb_build_object('codigo', x.codigo, 'nome', x.nome, 'estado', x.estado, 'obrigatorio', x.obrigatorio)
                   order by x.ordem) as itens
    from (
      select i.codigo, i.nome, i.ordem, i.obrigatorio,
             case when v.valor is null then 'vazio'
                  when public._mari_item_validado(i.regra_validado, v.valor, ch.j) then 'validado'
                  else 'coletado' end as estado
        from public.config_mari_itens i
        cross join lateral (select public._mari_item_valor(ch.j, i.fonte) as valor) v
       where i.ativo
         and i.segmento in ('ambos', case when ch.segmento = 'empresas' then 'empresas' else 'varejo' end)
    ) x
) tm on true
cross join lateral (
  select
    case when ch.elegibilidade in ('ja_cliente', 'cancelou_30d') or ch.handoff_motivo = 'ja_cliente_nio' then 'bloqueia'
         when ch.elegibilidade = 'ok' then 'ok' else 'pendente' end as trava_cliente_nio,
    case when ch.nio_viab_resultado = 'posse' or ch.dfv_resultado = 'endereco_ocupado' then 'bloqueia'
         when ch.nio_viab_resultado = 'viavel' or ch.dfv_resultado in ('viavel', 'viavel_predio') then 'ok' else 'pendente' end as trava_endereco_nio,
    case when ch.dentro_area is false or ch.handoff_motivo in ('fora_de_area', 'sem_cobertura') then 'bloqueia'
         when ch.nio_viab_resultado = 'viavel' or (ch.dentro_area and ch.dfv_resultado in ('viavel', 'viavel_predio')) then 'ok'
         else 'pendente' end as trava_viabilidade
) tr;

revoke all on public.v_mari_quadro from anon;
grant select on public.v_mari_quadro to authenticated;
