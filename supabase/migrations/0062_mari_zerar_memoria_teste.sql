-- NIOGEN | supabase/migrations/0062_mari_zerar_memoria_teste.sql | 08/11/2026 00h15 — Claude Code (pedido do Ricardo)
-- Por quê: no teste real de 08/11 00h01 o Ricardo mandou "Boa noite!" para começar um teste novo e a Mari continuou a
-- conversa anterior (retomada: a conversa resolvida no Chatwoot volta com o histórico, de propósito). Ricardo: "Precisamos
-- criar um comando pra 'apagar' a memória dela para eu iniciar os testes".
-- O quê: comando "#zerar" mandado no WhatsApp por um número da lista config_mari_textos.telefones_teste (só dígitos, como o
-- Chatwoot entrega — 55 + DDD + número; vírgula separa). mari_zerar_memoria encerra a conversa da Mari desse número
-- (status encerrado_humano + marca 'sistema'); NADA é apagado (turnos, venda e ficha ficam para auditoria). A próxima
-- mensagem cria uma conversa nova, sem histórico. Número fora da lista → ok=false e a mensagem segue o fluxo normal.
-- O n8n (2k → 2l → 2n) avisa pela Graph API (sem eco no Chatwoot), limpa as etiquetas e resolve a conversa no Chatwoot.

insert into public.config_mari_textos (chave, texto)
values ('telefones_teste', '553288015161')
on conflict (chave) do nothing;

create or replace function public.mari_zerar_memoria(p_telefone text, p_chatwoot_conversation_id text default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_tel   text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_lista text[];
  v_ids   uuid[];
begin
  select array_remove(regexp_split_to_array(regexp_replace(coalesce(texto, ''), '[^0-9,]', '', 'g'), ','), '')
    into v_lista from public.config_mari_textos where chave = 'telefones_teste';
  if v_tel !~ '^\d{10,15}$' or v_lista is null or not (v_tel = any (v_lista)) then
    return jsonb_build_object('ok', false, 'motivo', 'numero fora de telefones_teste');
  end if;

  with fechadas as (
    update public.mari_conversas
       set status = 'encerrado_humano', processando_ate = null
     where telefone = v_tel and canal = 'whatsapp' and status in ('ativo', 'handoff_realizado')
    returning id)
  select array_agg(id) into v_ids from fechadas;

  update public.mari_turnos set pendente = false where conversa_id = any (coalesce(v_ids, '{}')) and pendente;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  select id, 'sistema', '[memória da Mari zerada pelo comando #zerar (teste) — conversa ' || coalesce(p_chatwoot_conversation_id, '?')
         || ' do Chatwoot; a próxima mensagem abre uma conversa nova]', false
    from unnest(coalesce(v_ids, '{}')) as id;

  return jsonb_build_object('ok', true, 'conversas_encerradas', coalesce(cardinality(v_ids), 0));
end;
$$;
comment on function public.mari_zerar_memoria(text, text) is
  'Comando #zerar (0062): encerra a conversa da Mari de um número de teste (config_mari_textos.telefones_teste), sem apagar nada; a próxima mensagem começa do zero.';
revoke execute on function public.mari_zerar_memoria(text, text) from public, anon, authenticated;
grant execute on function public.mari_zerar_memoria(text, text) to service_role;
