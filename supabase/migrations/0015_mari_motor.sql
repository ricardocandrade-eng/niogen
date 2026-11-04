-- NIOGEN | supabase/migrations/0015_mari_motor.sql | 04/11/2026
-- Ajustes do motor da Mari (nó 7b anti-duplicata e nó 10 salvar turno):
--  * mari_abortar: chegou mensagem nova enquanto a Mari respondia → devolve as mensagens consumidas
--    para a fila (pendente) e libera o lock; a execução mais nova responde tudo junto (padrão 7b da Renata).
--  * mari_salvar_turno ganha número da casa (tag [ENDERECO]) e p_erro (grava em mari_erros);
--    endereço mudou → zera o DFV para o mari_contexto consultar de novo.
-- Idempotente.

create or replace function public.mari_abortar(p_conversa uuid, p_turno_ids bigint[])
returns jsonb language plpgsql set search_path = public as $$
begin
  update public.mari_turnos set pendente = true
   where conversa_id = p_conversa and id = any (coalesce(p_turno_ids, '{}'));
  update public.mari_conversas set processando_ate = null where id = p_conversa;
  return jsonb_build_object('ok', true);
end;
$$;

drop function if exists public.mari_salvar_turno(uuid, text, jsonb, text, int, int, int, jsonb, text);

create or replace function public.mari_salvar_turno(
  p_conversa uuid, p_texto text, p_tags jsonb default null, p_modelo text default null,
  p_tokens_in int default null, p_tokens_out int default null, p_latencia_ms int default null,
  p_upd jsonb default '{}'::jsonb, p_papel text default 'mari', p_erro jsonb default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  u jsonb := coalesce(p_upd, '{}'::jsonb);
  c public.mari_conversas;
  v_num  text;
  v_comp text;
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('ok', false, 'erro', 'conversa inexistente'); end if;

  if coalesce(p_texto, '') <> '' or p_tags is not null then
    insert into public.mari_turnos (conversa_id, papel, texto, tags, modelo, tokens_in, tokens_out, latencia_ms)
    values (p_conversa, p_papel, coalesce(p_texto, ''), p_tags, p_modelo, p_tokens_in, p_tokens_out, p_latencia_ms);
  end if;

  if p_erro is not null then
    insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
    values (p_conversa, coalesce(p_erro ->> 'no', 'mari_principal'), p_erro ->> 'mensagem', p_erro -> 'payload');
  end if;

  v_num  := case when u ? 'numero' then nullif(btrim(u ->> 'numero'), '') else c.numero end;
  v_comp := case when u ? 'complemento' then nullif(btrim(u ->> 'complemento'), '') else c.complemento end;

  update public.mari_conversas set
    etapa               = coalesce(u ->> 'etapa', etapa),
    elegibilidade       = coalesce(u ->> 'elegibilidade', elegibilidade),
    segmento            = coalesce(u ->> 'segmento', segmento),
    mei                 = coalesce((u ->> 'mei')::boolean, mei),
    plano_escolhido     = case when u ? 'plano_escolhido' then u ->> 'plano_escolhido' else plano_escolhido end,
    forma_pagamento     = coalesce(u ->> 'forma_pagamento', forma_pagamento),
    visita_preferencia  = coalesce(u ->> 'visita_preferencia', visita_preferencia),
    dados               = dados || coalesce(u -> 'dados', '{}'::jsonb),
    lgpd_enviada        = lgpd_enviada or coalesce((u ->> 'lgpd_enviada')::boolean, false),
    upsell_oferecido    = upsell_oferecido or coalesce((u ->> 'upsell_oferecido')::boolean, false),
    nome_confiavel      = coalesce((u ->> 'nome_confiavel')::boolean, nome_confiavel),
    agendamento_retorno = coalesce((u ->> 'agendamento_retorno')::timestamptz, agendamento_retorno),
    numero              = v_num,
    complemento         = v_comp,
    dfv_resultado       = case when row(v_num, v_comp) is distinct from row(c.numero, c.complemento) then null else dfv_resultado end,
    dfv_detalhe         = case when row(v_num, v_comp) is distinct from row(c.numero, c.complemento) then null else dfv_detalhe end,
    processando_ate     = null
  where id = p_conversa;

  return jsonb_build_object('ok', true);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.mari_abortar(uuid, bigint[])',
    'public.mari_salvar_turno(uuid, text, jsonb, text, int, int, int, jsonb, text, jsonb)']
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end;
$$;
