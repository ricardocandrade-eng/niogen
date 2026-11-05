-- NIOGEN | supabase/migrations/0027_biometria_link_do_chatwoot.sql | 05/11/2026 — Claude Code (pedido do Ricardo)
-- Captura automática do link da biometria: quando o atendente manda no Chatwoot (conversa da Mari) uma mensagem com
-- o link do portal (https://ged360.niointernet.com.br/brprontopdv/pdv-mobile/biometria/login/<código>), a fala já
-- chega aqui como turno 'humano' (nó 2 · Entrada → mari_registrar_turno). Agora, além de gravar o turno:
--   • conversa com venda em 0 · Qualificado e biometria ainda não validada → grava o link na venda, marca
--     biometria_status = pendente e biometria_link_enviado_em = agora (as 24 h / 72 h e o lembrete D+1 contam daí);
--   • link novo (reenvio) → troca o link e recomeça a contagem (o BIO1 volta a valer para o link novo);
--   • mesmo link de novo → não mexe; biometria validada, venda vendida ou sem venda → não mexe (só o turno);
--   • evento "biometria_link" na linha do tempo da venda (origem chatwoot).
-- O eco da própria Mari (cadência) continua ignorado antes daqui. Colar o link à mão na ficha continua valendo.

create or replace function public.mari_registrar_turno(
  p_telefone text, p_nome text, p_texto text, p_papel text, p_canal text default 'whatsapp',
  p_chatwoot_conversation_id text default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_tel  text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_txt  text := btrim(coalesce(p_texto, ''));
  v_conv public.mari_conversas;
  v_link text;
  v_venda record;
  v_capt text;
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

  -- 0027: link da biometria mandado pelo atendente → venda da conversa.
  if p_papel = 'humano' then
    v_link := substring(v_txt from '(https://ged360\.niointernet\.com\.br/brprontopdv/pdv-mobile/biometria/login/[A-Za-z0-9_-]+)');
    if v_link is not null then
      select v.id, v.status, v.biometria_status, v.biometria_link into v_venda
        from public.vendas v where v.id = v_conv.venda_id for update;
      if not found then
        v_capt := 'conversa sem venda no NIOGEN';
      elsif v_venda.status <> '0_qualificado' or v_venda.biometria_status = 'validada' then
        v_capt := 'venda já passou da biometria';
      elsif v_venda.biometria_link is not distinct from v_link and v_venda.biometria_status in ('pendente', 'com_risco') then
        v_capt := 'mesmo link já registrado';
      else
        update public.vendas
           set biometria_link = v_link,
               biometria_status = case when biometria_status = 'com_risco' then 'com_risco' else 'pendente' end,
               biometria_link_enviado_em = now()
         where id = v_venda.id;
        insert into public.eventos_venda (venda_id, tipo, detalhe)
        values (v_venda.id, 'biometria_link', jsonb_build_object(
          'origem', 'chatwoot', 'conversa_id', v_conv.id, 'reenvio', v_venda.biometria_link is not null));
        v_capt := case when v_venda.biometria_link is null then 'link registrado' else 'link trocado (reenvio)' end;
      end if;
    end if;
  end if;

  return jsonb_strip_nulls(jsonb_build_object('ignorado', false, 'conversa_id', v_conv.id, 'papel', p_papel,
                                              'biometria_link', v_capt));
end;
$$;
