-- NIOGEN | supabase/migrations/0021_mari_eco_por_balao.sql | 04/11/2026 — Claude Code (prompt v3, balões)
-- Com o prompt v3 a Mari responde em até 3 balões ("||"): o turno 'mari' é gravado inteiro (balões unidos por
-- linha em branco), mas o Chatwoot devolve UM eco por balão. A 0020 só reconhecia eco com texto IGUAL ao turno —
-- cada balão viraria um turno 'humano' falso. Aqui o eco é reconhecido também quando o texto recebido está
-- CONTIDO numa fala da Mari dos últimos 10 minutos. Compatível com a v2 (resposta de um balão = igual = contido).
-- Aplicar JUNTO com a troca da produção para a v3 (não antes é inofensivo; depois é obrigatório).
-- Idêntica à 0020 fora a condição do eco. Idempotente.

create or replace function public.mari_registrar_turno(
  p_telefone text, p_nome text, p_texto text, p_papel text,
  p_canal text default 'whatsapp', p_chatwoot_conversation_id text default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_tel  text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_txt  text := btrim(coalesce(p_texto, ''));
  v_conv public.mari_conversas;
begin
  if p_papel not in ('lead', 'humano') then
    raise exception 'papel inválido: % (use lead | humano)', p_papel using errcode = '22023';
  end if;
  if v_tel !~ '^\d{10,15}$' then
    raise exception 'telefone inválido' using errcode = '22023';
  end if;
  if v_txt = '' then
    return jsonb_build_object('ignorado', true, 'motivo', 'texto vazio');
  end if;

  select * into v_conv from public.mari_conversas
   where telefone = v_tel and canal = p_canal and status in ('ativo', 'handoff_realizado')
   for update;

  if not found then
    insert into public.mari_conversas (telefone, nome_contato, canal, origem, chatwoot_conversation_id)
    values (v_tel, nullif(btrim(p_nome), ''), p_canal,
            case when p_canal = 'teste' then 'teste' else 'direto' end, p_chatwoot_conversation_id)
    returning * into v_conv;
  end if;

  if p_papel = 'humano' then
    if exists (select 1 from public.mari_turnos
                where conversa_id = v_conv.id and papel = 'mari'
                  and (btrim(texto) = v_txt or position(v_txt in texto) > 0)
                  and created_at > now() - interval '10 minutes') then
      return jsonb_build_object('ignorado', true, 'motivo', 'eco da Mari', 'conversa_id', v_conv.id);
    end if;
    if exists (select 1 from public.mari_turnos
                where conversa_id = v_conv.id and papel = 'humano'
                  and btrim(texto) = v_txt and created_at > now() - interval '1 minute') then
      return jsonb_build_object('ignorado', true, 'motivo', 'repetido', 'conversa_id', v_conv.id);
    end if;
  end if;

  insert into public.mari_turnos (conversa_id, papel, texto, pendente, tags)
  values (v_conv.id, p_papel, v_txt, false, jsonb_build_object('sem_resposta', true));

  if p_papel = 'lead' then
    update public.mari_conversas
       set ultima_msg_lead_at = now(),
           nome_contato = coalesce(nome_contato, nullif(btrim(p_nome), ''))
     where id = v_conv.id;
  end if;

  return jsonb_build_object('ignorado', false, 'conversa_id', v_conv.id, 'papel', p_papel);
end;
$$;

revoke all on function public.mari_registrar_turno(text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.mari_registrar_turno(text, text, text, text, text, text) to service_role;
