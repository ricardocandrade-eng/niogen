-- NIOGEN | supabase/migrations/0052_cadencia_futuro_eco.sql | 07/11/2026 — Claude Code (prompt 28)
-- Resumo:
--   1. Interesse futuro (decisão 5 do prompt 28): venda em Saída "Interesse futuro (com data)" → o workflow
--      mari_cadencia põe a etiqueta `interesse-futuro` na conversa do Chatwoot (união com as atuais) + UMA nota
--      privada com a data de volta, e marca a conversa aqui (etiqueta_futuro_em / etiqueta_futuro_para).
--      Data trocada depois → nova nota com a data nova (a mesma data nunca gera nota duas vezes).
--      "Sem cobertura" e os outros motivos não ganham nada.
--   2. Eco do envio da cadência: o Chatwoot devolve a mensagem que a cadência mandou ao mari_principal, que só a
--      reconhece como eco se o turno 'mari' já estiver gravado. O envio (nó 7) vem ANTES do registro (nó 8), então
--      o eco pode chegar antes e virar turno 'humano' falso. mari_cadencia_registrar passa a apagar esse turno
--      'humano' de texto IGUAL ao enviado, da mesma conversa, criado depois do início da rodada. O mari_principal
--      não muda. Restante do registrar idêntico à 0025.
-- Idempotente.

alter table public.mari_conversas
  add column if not exists etiqueta_futuro_em   timestamptz,
  add column if not exists etiqueta_futuro_para date;

comment on column public.mari_conversas.etiqueta_futuro_em is
  '0052: quando a cadência pôs a etiqueta interesse-futuro + nota privada no Chatwoot.';
comment on column public.mari_conversas.etiqueta_futuro_para is
  '0052: data de volta (vendas.interesse_futuro_em) que a nota já informou. Diferente da venda = nota nova.';

create or replace function public.mari_futuro_pendentes(p_limite int default 20)
returns setof jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
           'conversa_id', c.id,
           'chatwoot_conversation_id', c.chatwoot_conversation_id,
           'venda_id', v.id,
           'volta_em', v.interesse_futuro_em,
           'nota', case when c.etiqueta_futuro_para is null
                        then 'Interesse futuro: o cliente pediu para voltarmos a falar em '
                        else 'Interesse futuro: a data de volta mudou para ' end
                   || to_char(v.interesse_futuro_em, 'DD/MM/YYYY')
                   || '. A venda está em Saída no NIOGEN; retome o contato nessa data (a etiqueta interesse-futuro marca a conversa).')
    from public.mari_conversas c
    join public.vendas v on v.id = c.venda_id
   where c.canal = 'whatsapp'
     and c.telefone not like '5500000000%'   -- telefone de teste nunca vai ao Chatwoot
     and c.chatwoot_conversation_id is not null
     and v.status = 'saida'
     and v.motivo_saida ilike 'Interesse futuro%'
     and v.interesse_futuro_em is not null
     and c.etiqueta_futuro_para is distinct from v.interesse_futuro_em
   order by v.interesse_futuro_em
   limit least(greatest(coalesce(p_limite, 20), 1), 20)
$$;

create or replace function public.mari_futuro_marcar(p_conversa uuid, p_para date)
returns jsonb language plpgsql set search_path = public as $$
declare
  c public.mari_conversas;
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('ok', false, 'erro', 'conversa inexistente'); end if;
  update public.mari_conversas set etiqueta_futuro_em = now(), etiqueta_futuro_para = p_para where id = p_conversa;
  if c.venda_id is not null then
    insert into public.eventos_venda (venda_id, tipo, detalhe)
    values (c.venda_id, 'chatwoot_etiqueta', jsonb_build_object(
      'etiqueta', 'interesse-futuro', 'volta_em', p_para, 'conversa_id', c.id, 'nota_privada', true,
      'troca_de_data', c.etiqueta_futuro_para is not null));
  end if;
  return jsonb_build_object('ok', true, 'conversa_id', p_conversa, 'volta_em', p_para);
end;
$$;

create or replace function public.mari_cadencia_registrar(
  p_conversa uuid, p_passo text, p_ok boolean, p_erro text default null, p_agora timestamptz default now(),
  p_texto text default null, p_excecao text default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  c public.mari_conversas;
  v_bio timestamptz;
  v_inst timestamptz;
  v_prox record;
  v_eco int := 0;
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('ok', false, 'erro', 'conversa inexistente'); end if;

  if not coalesce(p_ok, false) then
    insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
    values (p_conversa, 'mari_cadencia', 'envio da cadência falhou (' || coalesce(p_passo, '?') || '): ' || coalesce(p_erro, 'sem detalhe'),
            jsonb_build_object('passo', p_passo, 'agora', p_agora));
    return jsonb_build_object('ok', true, 'registrado', 'erro');
  end if;

  if p_passo = 'ENCERRAR' then
    update public.mari_conversas set status = 'encerrado_ia', handoff_motivo = 'sem_contato',
           cadencia_passo = 'encerrada', cadencia_passo_em = p_agora, cadencia_proximo_em = null
     where id = p_conversa;
    insert into public.mari_turnos (conversa_id, papel, texto, tags, created_at)
    values (p_conversa, 'sistema', 'Saída "Sem contato": 48 h sem resposta depois do D15.',
            jsonb_build_object('cadencia', 'ENCERRAR'), p_agora);
    return jsonb_build_object('ok', true, 'registrado', 'encerrada');
  end if;
  if p_passo = 'BIO3' then
    return jsonb_build_object('ok', false, 'erro', 'BIO3 é ligação do nosso time: nunca registrada como envio automático');
  end if;

  insert into public.mari_turnos (conversa_id, papel, texto, tags, created_at)
  values (p_conversa, 'mari', coalesce(p_texto, ''),
          jsonb_strip_nulls(jsonb_build_object('cadencia', p_passo, 'excecao', p_excecao, 'simulado', c.canal = 'teste')), p_agora);

  -- 0052: eco do próprio envio que chegou ao mari_principal ANTES deste registro (virou turno 'humano' falso).
  if c.canal = 'whatsapp' and coalesce(btrim(p_texto), '') <> '' then
    delete from public.mari_turnos t
     where t.conversa_id = p_conversa and t.papel = 'humano'
       and btrim(t.texto) = btrim(p_texto)
       and t.created_at >= p_agora - interval '1 minute'
       and t.created_at <= now() + interval '1 minute';
    get diagnostics v_eco = row_count;
  end if;

  insert into public.contatos_cliente (venda_id, conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
  values (c.venda_id, c.id, c.telefone, 'whatsapp', 'saida', 'mari', p_agora, p_passo, 'ativo',
          'cadência ' || p_passo || coalesce(' · ' || p_excecao, '') || case when c.canal = 'teste' then ' (simulado)' else '' end);

  if p_passo = 'RETORNO' then
    update public.mari_conversas set cadencia_retorno_em = p_agora,
           cadencia_passo = case when cadencia_passo in ('nenhum', 'F1', 'P1') then 'F2' else cadencia_passo end,
           cadencia_passo_em = p_agora
     where id = p_conversa;
  elsif p_passo = 'VISITA' then   -- histórico (0018); não é mais gerado
    select biometria_em into v_bio from public.vendas where id = c.venda_id;
    update public.mari_conversas set visita_confirmada_para = v_bio where id = p_conversa;
  elsif p_passo = 'BIO1' then
    update public.mari_conversas set bio_lembrete_em = p_agora where id = p_conversa;
  elsif p_passo = 'INSTALACAO' then
    select instalacao_agendada_para into v_inst from public.vendas where id = c.venda_id;
    update public.mari_conversas set instalacao_avisada_para = v_inst, instalacao_avisada_em = p_agora where id = p_conversa;
  elsif p_passo = 'VESPERA' then
    select instalacao_agendada_para into v_inst from public.vendas where id = c.venda_id;
    update public.mari_conversas set instalacao_lembrada_para = v_inst where id = p_conversa;
  else
    update public.mari_conversas set cadencia_passo = p_passo, cadencia_passo_em = p_agora where id = p_conversa;
  end if;

  select a.proximo_passo, a.proximo_em into v_prox
    from public.mari_cadencia_avaliar(p_agora + interval '1 second', p_conversa) a limit 1;
  update public.mari_conversas set cadencia_proximo_em = v_prox.proximo_em where id = p_conversa;

  return jsonb_build_object('ok', true, 'registrado', p_passo, 'proximo_passo', v_prox.proximo_passo,
                            'proximo_em', v_prox.proximo_em, 'eco_removido', v_eco);
end;
$$;

revoke all on function public.mari_futuro_pendentes(int) from public, anon, authenticated;
revoke all on function public.mari_futuro_marcar(uuid, date) from public, anon, authenticated;
grant execute on function public.mari_futuro_pendentes(int) to service_role;
grant execute on function public.mari_futuro_marcar(uuid, date) to service_role;
