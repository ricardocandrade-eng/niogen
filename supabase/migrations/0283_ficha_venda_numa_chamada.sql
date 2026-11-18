-- NIOGEN | supabase/migrations/0283_ficha_venda_numa_chamada.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Reta final, item 6 (regra 19: ≤ 25 chamadas por abertura). Medido em 18/11 ~11h45, logado no site publicado (admin, Live → ficha):
-- 22–38 chamadas por abertura, 0,84–1,33 s. Treze delas são leituras só da venda, cada uma uma ida e volta a Oregon.
-- ficha_venda(p_venda) devolve as treze num jsonb só:
--   v (v_vendas) · eventos (eventos_venda) · lim (v_contatos_limite) · adics (venda_adicionais + config_adicionais) ·
--   conv (mari_conversas da venda, só admin/backoffice, mesmas colunas da tela) · contatos (contatos_cliente, 30 últimos) ·
--   extra (colunas de vendas que a v_vendas não traz) · pend (venda_pendencias) · avisos (ficha_avisos) ·
--   andamento (v_venda_andamento, só admin/backoffice) · lead (v_leads) · din (v_dinheiro) · meta (v_venda_meta, só admin/backoffice).
-- SECURITY INVOKER: cada leitura passa pela mesma RLS de quando a tela lia direto. Cada parte tem a própria proteção: erro numa
-- parte devolve nulo nela (como o opc() da tela) e o resto segue; erro na v_vendas vem em v_erro.
-- Só leitura. Regra 20: nenhum estado, situação, evento ou número novo (1–5 não se aplicam); tela Live sem mudança (a ficha abre
-- por cima dela, mas a mudança é no ficha.js). Guia do backoffice: sem impacto.
begin;

create or replace function public.ficha_venda(p_venda uuid)
returns jsonb language plpgsql stable security invoker set search_path to 'public' as $function$
declare
  r  jsonb := '{}'::jsonb;
  bo boolean := coalesce((select public.meu_perfil()), '') in ('admin', 'backoffice');
  x  jsonb;
  conv_cols text[] := array['id', 'chatwoot_conversation_id', 'chatwoot_agente', 'chatwoot_time', 'chatwoot_status', 'chatwoot_etiquetas',
    'humano_atribuido', 'nao_contatar', 'ultima_msg_lead_at', 'handoff_briefing', 'handoff_em', 'handoff_motivo', 'cobertura_decisao',
    'nio_viab_resultado', 'nio_viab_velocidade', 'credito_resultado', 'credito_em', 'credito_endereco', 'credito_formas', 'credito_consultas',
    'forma_pagamento', 'nio_pedido_aberto', 'antifraude_situacao', 'antifraude_em', 'antifraude_hist', 'funil_etapa', 'funil_destino',
    'funil_detalhe', 'funil_alerta', 'status', 'origem', 'created_at', 'cadencia_passo', 'cadencia_retorno_em', 'agendamento_retorno',
    'chatwoot_resolvida', 'time_atribuido', 'venda_id', 'bio_lembrete_em', 'instalacao_avisada_para', 'instalacao_avisada_em'];
  extra_cols text[] := array['nio_viab_por', 'ponto_referencia', 'nio_os', 'nio_os_em', 'contato_nome', 'contato_relacao', 'nio_interesse',
    'nio_interesse_em', 'titular_trocado_em', 'docs_dispensados_em', 'biometria_dispensada_em', 'biometria_dispensa_motivo', 'cartao_pago_em',
    'conferencia_obs', 'conferencia_em', 'conferencia_por', 'parceiro_indevida', 'parceiro_indevida_motivo', 'parceiro_indevida_em'];
begin
  begin
    select to_jsonb(t) into x from public.v_vendas t where t.id = p_venda;
    r := r || jsonb_build_object('v', x);
  exception when others then r := r || jsonb_build_object('v', null, 'v_erro', sqlerrm); end;
  if r -> 'v' is null or jsonb_typeof(r -> 'v') = 'null' then return r; end if;

  begin
    select coalesce(jsonb_agg(to_jsonb(e) order by e.criado_em), '[]'::jsonb) into x from public.eventos_venda e where e.venda_id = p_venda;
    r := r || jsonb_build_object('eventos', x);
  exception when others then r := r || jsonb_build_object('eventos', null); end;

  begin
    select to_jsonb(t) into x from public.v_contatos_limite t where t.venda_id = p_venda limit 1;
    r := r || jsonb_build_object('lim', x);
  exception when others then r := r || jsonb_build_object('lim', null); end;

  begin
    select coalesce(jsonb_agg(jsonb_build_object('qtd', a.qtd, 'comissao_prevista', a.comissao_prevista,
             'config_adicionais', (select jsonb_build_object('nome', ca.nome, 'preco', ca.preco) from public.config_adicionais ca where ca.id = a.adicional_id))
             order by a.id), '[]'::jsonb)
      into x from public.venda_adicionais a where a.venda_id = p_venda;
    r := r || jsonb_build_object('adics', x);
  exception when others then r := r || jsonb_build_object('adics', null); end;

  if bo then
    begin
      select coalesce(jsonb_agg(y), '[]'::jsonb) into x from (
        select (select jsonb_object_agg(k, val) from jsonb_each(to_jsonb(m)) j(k, val) where k = any(conv_cols)) y
          from public.mari_conversas m where m.venda_id = p_venda order by m.created_at desc limit 1) s;
      r := r || jsonb_build_object('conv', x);
    exception when others then r := r || jsonb_build_object('conv', null); end;
  else
    r := r || jsonb_build_object('conv', '[]'::jsonb);
  end if;

  begin
    select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'canal', k.canal, 'direcao', k.direcao, 'por', k.por, 'em', k.em,
             'resumo', k.resumo, 'toque', k.toque) order by k.em desc), '[]'::jsonb)
      into x from (select * from public.contatos_cliente c where c.venda_id = p_venda order by c.em desc limit 30) k;
    r := r || jsonb_build_object('contatos', x);
  exception when others then r := r || jsonb_build_object('contatos', null); end;

  begin
    select (select jsonb_object_agg(k, val) from jsonb_each(to_jsonb(t)) j(k, val) where k = any(extra_cols)) into x
      from public.vendas t where t.id = p_venda;
    r := r || jsonb_build_object('extra', x);
  exception when others then r := r || jsonb_build_object('extra', null); end;

  begin
    select coalesce(jsonb_agg(to_jsonb(p) order by p.aberta_em desc), '[]'::jsonb) into x from public.venda_pendencias p where p.venda_id = p_venda;
    r := r || jsonb_build_object('pend', x);
  exception when others then r := r || jsonb_build_object('pend', null); end;

  begin
    r := r || jsonb_build_object('avisos', public.ficha_avisos(p_venda => p_venda));
  exception when others then r := r || jsonb_build_object('avisos', null, 'avisos_erro', true); end;

  if bo then
    begin
      select to_jsonb(t) into x from public.v_venda_andamento t where t.venda_id = p_venda limit 1;
      r := r || jsonb_build_object('andamento', x);
    exception when others then r := r || jsonb_build_object('andamento', null); end;
    begin
      select to_jsonb(t) into x from public.v_venda_meta t where t.venda_id = p_venda limit 1;
      r := r || jsonb_build_object('meta', x);
    exception when others then r := r || jsonb_build_object('meta', null); end;
  end if;

  begin
    select to_jsonb(t) into x from public.v_leads t where t.venda_id = p_venda limit 1;
    r := r || jsonb_build_object('lead', x);
  exception when others then r := r || jsonb_build_object('lead', null); end;

  begin
    select to_jsonb(t) into x from public.v_dinheiro t where t.venda_id = p_venda limit 1;
    r := r || jsonb_build_object('din', x);
  exception when others then r := r || jsonb_build_object('din', null); end;

  return r;
end $function$;

revoke execute on function public.ficha_venda(uuid) from public, anon;
grant execute on function public.ficha_venda(uuid) to authenticated, service_role;

commit;
