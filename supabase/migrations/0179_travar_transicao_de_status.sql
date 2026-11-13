-- NIOGEN | 0179_travar_transicao_de_status.sql | 13/11/2026 — Claude Code (etapa 6, fatia 6e — Ricardo: "Vamos fazer então")
-- Regra 3 do plano do sistema fechado: "todo estado muda por uma função do banco, com motivo e autor". Até hoje nada impedia
-- PULAR nem VOLTAR degrau: 0 → Ativa passava, Ativa → Vendida passava, e backoffice e vendedor gravavam status direto.
--
-- O que passa a valer (gatilho vendas_a_transicao, antes dos outros gatilhos de status):
--   • Caminho natural, sem motivo — é o que as telas e as funções já fazem hoje, nada disso muda:
--       Qualificado → Vendida / Ativação · Vendida → Ativação / Instalada · Ativação → Instalada · Instalada → Ativa ·
--       Ativa → Comissão firme · qualquer um antes de instalar → Saída · Saída → onde parou (reabrir).
--   • Tudo o mais (voltar degrau, pular para Ativa, tirar uma instalada da jornada) é RECUSADO na gravação direta e só passa
--     por função do banco que diga por quê:
--       venda_mover_admin(venda, destino, motivo) — só admin, motivo obrigatório, fica no histórico da venda;
--       _portal_aplicar (o portal da Nio diz "instalada": leva a Ativa de onde estiver).
-- As travas que já existiam (vendas_antes_status: pedido, biometria, OS, viabilidade, data) continuam valendo em qualquer caminho.
-- Não muda: mari_conversas (já não aceita escrita de usuário), a Saída (lead_sair/lead_reabrir) e as funções do OSAB e do
-- Operador de OS, que só andam para a frente pelo caminho natural.

create or replace function public._status_nome(p text) returns text language sql immutable as $$
  select case p when '0_qualificado' then 'Qualificado' when '1_vendido' then 'Vendida' when '2_aguardando_instalacao' then 'Ativação/Agenda'
                when '3_instalado' then 'Instalada' when '4_ativo_provisorio' then 'Ativa' when '5_comissao_firme' then 'Comissão firme'
                when 'saida' then 'Saída' else coalesce(p, '—') end;
$$;
revoke all on function public._status_nome(text) from public, anon, authenticated;

create or replace function public.vendas_transicao()
returns trigger language plpgsql set search_path = public as $$
declare
  de   text := old.status;
  para text := new.status;
  ok   boolean;
begin
  if de is not distinct from para then return new; end if;
  -- função do banco que assumiu a mudança (venda_mover_admin, _portal_aplicar): vale para esta transação só
  if coalesce(current_setting('niogen.transicao_ok', true), '') <> '' then return new; end if;
  ok := case de
    when '0_qualificado'           then para in ('1_vendido', '2_aguardando_instalacao', 'saida')
    when '1_vendido'               then para in ('2_aguardando_instalacao', '3_instalado', 'saida')
    when '2_aguardando_instalacao' then para in ('3_instalado', 'saida')
    when '3_instalado'             then para in ('4_ativo_provisorio')
    when '4_ativo_provisorio'      then para in ('5_comissao_firme')
    when 'saida'                   then para in ('0_qualificado', '1_vendido', '2_aguardando_instalacao')
    else false end;
  if not ok then
    raise exception 'Essa mudança de etapa não pode ser feita direto (de % para %). Voltar ou pular degrau é só do admin, pelo menu ⋯ › Mover para, com o motivo.',
      public._status_nome(de), public._status_nome(para) using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.vendas_transicao() from public, anon, authenticated;
drop trigger if exists vendas_a_transicao on public.vendas;
create trigger vendas_a_transicao before update of status on public.vendas
  for each row execute function public.vendas_transicao();

-- O "Mover para" do admin: qualquer destino que não seja Saída (a Saída tem a função dela), com motivo e registro.
create or replace function public.venda_mover_admin(p_venda uuid, p_destino text, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v public.vendas%rowtype;
  m text := btrim(coalesce(p_motivo, ''));
begin
  if public.meu_perfil() is distinct from 'admin' then
    raise exception 'Só o admin move a venda fora do caminho natural.' using errcode = '42501';
  end if;
  if length(m) < 5 then raise exception 'Diga o motivo (pelo menos 5 letras).' using errcode = 'P0001'; end if;
  if p_destino not in ('0_qualificado', '1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio') then
    raise exception 'Destino inválido. A Saída é pelo botão Saída.' using errcode = 'P0001';
  end if;
  select * into v from public.vendas where id = p_venda for update;
  if not found then raise exception 'Venda não encontrada.' using errcode = 'P0001'; end if;
  if v.status = p_destino then return jsonb_build_object('ok', true, 'mudou', false); end if;
  if v.status = 'saida' then raise exception 'A venda está em Saída: reabra pela ficha.' using errcode = 'P0001'; end if;
  perform set_config('niogen.transicao_ok', 'admin', true);
  update public.vendas set status = p_destino where id = p_venda;
  perform set_config('niogen.transicao_ok', '', true);
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (p_venda, 'movida_admin', jsonb_build_object('de', v.status, 'para', p_destino, 'motivo', left(m, 400)), auth.uid());
  return jsonb_build_object('ok', true, 'mudou', true, 'de', v.status, 'para', p_destino);
end;
$$;
revoke all on function public.venda_mover_admin(uuid, text, text) from public, anon;
grant execute on function public.venda_mover_admin(uuid, text, text) to authenticated;

-- _portal_aplicar: recriada a partir da produção (pg_get_functiondef em 13/11/2026); só entra a linha que assume o salto.
CREATE OR REPLACE FUNCTION public._portal_aplicar(p_pp portal_pedidos, p_quem uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cfg   public.config_portal_status;
  v     public.vendas;
  feito text := null;
  al    text := null;
  niv   text := null;
begin
  select * into cfg from public.config_portal_status where parceiro_id = p_pp.parceiro_id and status = p_pp.status;
  if not found then
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', 'status sem regra (só etiqueta)');
  end if;
  if cfg.acao = 'alerta' then
    return jsonb_build_object('alerta', cfg.texto, 'nivel', cfg.nivel, 'feito', 'alerta');
  end if;
  if p_pp.venda_id is null or cfg.acao = 'etiqueta' then
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', null);
  end if;
  select * into v from public.vendas where id = p_pp.venda_id for update;
  if not found or v.status = 'saida' then
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', 'venda em Saída: nada muda');
  end if;

  -- Pedido Gerado (e todo status adiante): venda sem nº ou com nº provisório ganha o nº do portal.
  if cfg.acao in ('pedido', 'biometria_validada', 'instalada')
     and (coalesce(btrim(v.nio_pedido), '') = '' or v.nio_pedido ilike 'PROV-%') then
    update public.vendas set nio_pedido = p_pp.pedido_nio where id = v.id returning * into v;
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'pedido_aberto_portal', jsonb_build_object('origem', 'portal_historico', 'pedido', p_pp.pedido_nio), p_quem);
    feito := 'nº do pedido gravado';
  end if;

  -- Venda (contrato ativo, sem instalação) e Gross: a biometria foi aprovada na Nio.
  if cfg.acao in ('biometria_validada', 'instalada') and v.biometria_status is distinct from 'validada' then
    update public.vendas set biometria_status = 'validada' where id = v.id returning * into v;
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'biometria_validada', jsonb_build_object('origem', 'portal', 'status_portal', p_pp.status), p_quem);
    feito := concat_ws(' · ', feito, 'biometria validada (portal)');
  end if;

  -- Gross: instalada e apta à comissão = o mesmo status da importação OSAB para "Concluído e válido" (4_ativo_provisorio).
  if cfg.acao = 'instalada' and v.status not in ('4_ativo_provisorio', '5_comissao_firme') then
    begin
      perform set_config('niogen.transicao_ok', 'portal', true);   -- 0179: o portal da Nio diz instalada — o salto é da fonte da verdade
      update public.vendas set status = '4_ativo_provisorio', instalado_em = coalesce(instalado_em, now()) where id = v.id returning * into v;
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'instalada_portal', jsonb_build_object('origem', 'portal', 'status_portal', p_pp.status), p_quem);
      feito := concat_ws(' · ', feito, 'Instalada (Gross)');
    exception when others then
      -- A trava da venda recusou (falta OS, viabilidade…): não força; avisa o que falta.
      al := 'Portal: Gross (instalada) · o NIOGEN não conseguiu marcar Instalada — ' || sqlerrm;
      niv := 'hoje';
    end;
  end if;
  return jsonb_build_object('alerta', al, 'nivel', niv, 'feito', feito);
end;
$function$;
