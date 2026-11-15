-- NIOGEN | supabase/migrations/0225_saida_ja_cliente_fica_com_time.sql | 15/11/2026 — Claude Code (Opus 5.5)
-- Correção da 0224 (achada na revisão dos fluxos, docs/REVISAO_ciclo_fluxos_151126_1920.md, D1): a Saída devolvia QUALQUER motivo
-- para a Mari, mas "já é cliente Nio" é suporte e fica com o time (regra da 0200; a Mari não atende cliente Nio). Agora só
-- "não contatar" e "já é cliente Nio" ficam fora da devolução. Nenhuma saída "já é cliente Nio" foi devolvida desde a 0224
-- (conferido: só Lucas — crédito negado — e Mauricio — sem resposta). Só lead_sair muda. Regra 20: sem estado novo.
begin;
create or replace function public.lead_sair(p_conversa uuid, p_venda uuid, p_motivo text, p_sub text default null,
                                            p_volta date default null, p_obs text default null, p_cancelou_portal boolean default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  k       public.config_lead;
  c       public.mari_conversas;
  v       public.vendas;
  perfil  text := coalesce(public.meu_perfil(), '');
  sub     text := nullif(btrim(coalesce(p_sub, '')), '');
  antigo  text;
  aberto  boolean := false;
  feito   text[] := '{}';
  g2      uuid;
begin
  if perfil not in ('admin', 'backoffice', 'vendedor') then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into k from public.config_lead where parceiro_id = 'dharma' and tipo = 'saida' and codigo = p_motivo;
  if not found then raise exception 'Motivo de saída desconhecido: %', p_motivo; end if;
  if p_conversa is not null then
    select * into c from public.mari_conversas where id = p_conversa;
    if not found then raise exception 'Conversa não encontrada.'; end if;
  end if;
  if coalesce(p_venda, c.venda_id) is not null then
    select * into v from public.vendas where id = coalesce(p_venda, c.venda_id) for update;
    if not found then raise exception 'Venda não encontrada.'; end if;
    if c.id is null then
      select * into c from public.mari_conversas where venda_id = v.id and canal = 'whatsapp' order by created_at desc limit 1;
    end if;
  end if;
  if v.id is null and c.id is null then raise exception 'Informe a conversa ou a venda.'; end if;
  if perfil = 'vendedor' and (v.id is null or auth.uid() not in (v.vendedor_id, v.criado_por)) then
    raise exception 'Vendedor só registra a saída da própria venda.' using errcode = '42501';
  end if;
  if p_motivo = 'recusou' and sub is null then raise exception 'Diga o porquê da recusa: preço, concorrente, momento, desistiu ou outro.'; end if;
  if p_volta is not null and p_volta <= (now() at time zone 'America/Sao_Paulo')::date then raise exception 'A data de volta precisa ser futura.'; end if;

  if v.id is not null then
    if v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') then
      raise exception 'Venda instalada não vai para Saída. Cancelamento depois de instalar vem do OSAB.';
    end if;
    aberto := nullif(btrim(v.nio_pedido), '') is not null or nullif(btrim(v.nio_os), '') is not null;
    if aberto and p_cancelou_portal is null then
      raise exception 'Esta venda tem pedido aberto na Nio. Diga se o pedido já foi cancelado no portal.';
    end if;
    update public.vendas
       set status = 'saida',
           motivo_saida = k.nome || coalesce(' · ' || sub, '') || coalesce(' — ' || nullif(btrim(p_obs), ''), ''),
           interesse_futuro_em = p_volta, saida_motivo = k.codigo, saida_sub = sub
     where id = v.id;
    feito := feito || ('Saída · ' || k.nome)::text;
    if aberto and p_cancelou_portal then
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'cancelado_no_portal', jsonb_build_object('quando', 'na saída'), auth.uid());
      feito := feito || 'pedido cancelado no portal (confirmado)'::text;
    elsif aberto then
      feito := feito || 'falta cancelar o pedido na Nio — a linha fica na Live até confirmar'::text;
    end if;
  else
    -- conversa sem venda: passa pelo caminho de sempre (nota, etiqueta e resolve no Chatwoot)
    if p_motivo in ('reprovado_biometria', 'nio_nao_instalou', 'venda_indevida_fraude') then
      raise exception 'Esse motivo só vale para lead com venda.';
    end if;
    antigo := case p_motivo when 'cidade_nao_atendida' then 'fora_area' when 'fachada_nao_atendida' then 'sem_cobertura'
                            when 'nao_contatar' then 'recusou' else p_motivo end;
    if p_motivo = 'nao_contatar' then perform public.conversa_nao_contatar(c.id, 'saída registrada no NIOGEN'); end if;
    perform public.backoffice_conversa_saida(c.id, antigo);
    feito := feito || ('Saída · ' || k.nome)::text;
  end if;

  if c.id is not null then
    update public.mari_conversas
       set saida_motivo = k.codigo, saida_sub = sub, saida_volta_em = p_volta, saida_em = now()
     where id = c.id;
  end if;
  -- 0224 (Ricardo, caso Lucas Heleno: "Dei saída… Não deveria ter voltado para a Mari?"): a Saída devolve a conversa para a Mari
  -- na hora (antes só depois de 24 h, pela 0200). Se o cliente voltar a escrever, é ela quem responde. "Não contatar" fica calado
  -- e "já é cliente Nio" fica com o time (0225).
  -- Crédito negado fica gravado também na conversa, para a Mari não consultar de novo o mesmo CPF.
  if c.id is not null and p_motivo = 'credito_negado' then
    update public.mari_conversas set credito_resultado = 'negado', credito_em = coalesce(credito_em, now()) where id = c.id;
  end if;
  -- 0225: "já é cliente Nio" fica com o time (suporte; regra da 0200) — a Mari não atende cliente Nio.
  if c.id is not null and p_motivo not in ('nao_contatar', 'ja_cliente_nio')
     and (coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null or c.status = 'handoff_realizado') then
    update public.mari_conversas set humano_atribuido = false, time_atribuido = false where id = c.id;
    if c.status = 'handoff_realizado' then
      perform public._mari_fechar_ciclo(c.id, 'saída registrada no NIOGEN — a conversa volta para a Mari');
    end if;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[saída "' || k.nome || '" registrada — a conversa voltou para a Mari]', false);
    if coalesce(c.chatwoot_conversation_id, '') <> '' and c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%' then
      g2 := gen_random_uuid();
      perform public._bo_enfileirar(g2, 1, 'saida_devolver', v.id, c, 'etiquetas',
        jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
      perform public._bo_enfileirar(g2, 2, 'saida_devolver', v.id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      perform public._bo_enfileirar(g2, 3, 'saida_devolver', v.id, c, 'desatribuir', jsonb_build_object('team_id', null));
      perform public._bo_enfileirar(g2, 4, 'saida_devolver', v.id, c, 'nota',
        jsonb_build_object('content', '↩ Saída "' || k.nome || '" registrada — a conversa voltou para a Mari. Se o cliente escrever, ela responde.'));
    end if;
    feito := feito || 'conversa devolvida para a Mari'::text;
  end if;
  if p_volta is not null then feito := feito || ('volta para a Live em ' || to_char(p_volta, 'DD/MM'))::text; end if;
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'pedido_aberto', aberto and not coalesce(p_cancelou_portal, false),
                            'resumo', '✓ ' || array_to_string(feito, ' · '));
end;
$$;

commit;
