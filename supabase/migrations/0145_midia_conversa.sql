-- NIOGEN | supabase/migrations/0145_midia_conversa.sql | 12/11/2026 — Claude Code
-- docs/Prompt_midia_transcricao_121126_0230.md (Ricardo, 12/11 02h28: "Sim e com a transcrição"). O prompt reservava a 0133,
-- já ocupada — esta é a 0145.
--   1. mari_turnos ganha midia jsonb (lista [{tipo, mime, ext, caminho, tamanho, transcricao, transcrito_em, erro, url_ia, url_ia_ate}])
--      e parceiro_id (regra 15: tabela antiga ganha a coluna quando é mexida).
--   2. Bucket PRIVADO midia_conversas (mari/<chatwoot_conversa>/<mensagem>_<n>.<ext> — sem "dharma": o export da Mari recusa a palavra), 16 MB, só áudio e imagem.
--      Leitura: logado admin/backoffice (as mesmas regras de quem lê mari_turnos). Escrita: só service role (n8n). Nada público.
--   3. mari_entrada e mari_registrar_turno ganham p_midia (opcional; chamada antiga segue igual). Turno do time nunca grava mídia.
--   4. mari_consolidar devolve "midia" das mensagens de agora (o motor manda a foto ao Claude).
-- url_ia = link assinado de 15 min, gerado pelo n8n só para o Claude ver a foto; vence sozinho e o front não usa.

begin;

-- 1 ─ colunas
alter table public.mari_turnos add column if not exists midia jsonb;
alter table public.mari_turnos add column if not exists parceiro_id text not null default 'dharma';

-- só lista de objetos; qualquer outra coisa vira null (o n8n nunca derruba a entrada por causa da mídia)
create or replace function public._midia_ok(p jsonb) returns jsonb
 language sql immutable set search_path to 'public'
as $$ select case when jsonb_typeof(p) = 'array' and jsonb_array_length(p) > 0 then p end $$;
revoke execute on function public._midia_ok(jsonb) from public, anon, authenticated;
grant execute on function public._midia_ok(jsonb) to service_role;

-- 2 ─ bucket privado
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('midia_conversas', 'midia_conversas', false, 16777216,
        array['audio/ogg', 'audio/opus', 'audio/mpeg', 'audio/mp4', 'audio/m4a', 'audio/x-m4a', 'audio/aac', 'audio/amr', 'audio/wav',
              'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists midia_conversas_ler on storage.objects;
create policy midia_conversas_ler on storage.objects for select to authenticated
  using (bucket_id = 'midia_conversas' and (select public.meu_perfil()) = any (array['admin', 'backoffice']));

-- 3 ─ entrada com mídia (assinatura nova: a antiga sai para o PostgREST não ficar em dúvida)
drop function if exists public.mari_entrada(text, text, text, text, text, text);
drop function if exists public.mari_registrar_turno(text, text, text, text, text, text);

CREATE OR REPLACE FUNCTION public.mari_entrada(p_telefone text, p_nome text, p_texto text, p_canal text DEFAULT 'teste'::text, p_origem text DEFAULT NULL::text, p_chatwoot_conversation_id text DEFAULT NULL::text, p_midia jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_tel  text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_conv public.mari_conversas;
  v_ts   timestamptz := clock_timestamp();
  v_orig text := case when p_origem in ('meta_ads', 'instagram', 'facebook', 'site', 'fila_vero', 'indicacao', 'direto', 'teste') then p_origem end;
  v_cw   text := nullif(btrim(coalesce(p_chatwoot_conversation_id, '')), '');
  v_pos  boolean;
begin
  if v_tel !~ '^\d{10,15}$' then
    raise exception 'telefone inválido' using errcode = '22023';
  end if;

  select * into v_conv from public.mari_conversas
   where telefone = v_tel and canal = p_canal and status in ('ativo', 'handoff_realizado')
   for update;

  if not found then
    insert into public.mari_conversas (telefone, nome_contato, canal, origem, chatwoot_conversation_id)
    values (v_tel, nullif(btrim(p_nome), ''), p_canal,
            coalesce(v_orig, case when p_canal = 'teste' then 'teste' else 'direto' end),
            p_chatwoot_conversation_id)
    returning * into v_conv;
  elsif v_conv.origem = 'direto' and v_orig in ('meta_ads', 'instagram', 'facebook', 'site', 'fila_vero', 'indicacao') then
    -- 0033: conversa que já existia sem origem conhecida ganha a 1ª origem identificada (link (IG)/(FB) ou anúncio).
    update public.mari_conversas set origem = v_orig where id = v_conv.id returning * into v_conv;
  end if;

  if v_conv.status = 'handoff_realizado' and p_canal = 'whatsapp' and v_cw is not null
        and v_conv.chatwoot_conversation_id is distinct from v_cw then
    perform public._mari_fechar_ciclo(v_conv.id, 'nova conversa no Chatwoot (' || v_cw || ')');
    update public.mari_conversas set chatwoot_conversation_id = v_cw
     where id = v_conv.id returning * into v_conv;
  end if;

  v_pos := public._mari_pos_handoff(v_conv);

  insert into public.mari_turnos (conversa_id, papel, texto, pendente, midia)
  values (v_conv.id, 'lead', coalesce(p_texto, ''), v_conv.status = 'ativo' or v_pos, public._midia_ok(p_midia));

  update public.mari_conversas
     set ultima_entrada_ts = v_ts,
         ultima_msg_lead_at = now(),
         nome_contato = coalesce(nome_contato, nullif(btrim(p_nome), ''))
   where id = v_conv.id;

  return jsonb_build_object(
    'conversa_id', v_conv.id,
    'ts', v_ts,
    'status', v_conv.status,
    'silencio', v_conv.status <> 'ativo' and not v_pos,   -- em handoff: humano conduz, Mari calada (salvo a janela 0061)
    'pos_handoff', v_pos,
    'nova', v_conv.created_at >= now() - interval '1 second');
end;
$function$;

CREATE OR REPLACE FUNCTION public.mari_registrar_turno(p_telefone text, p_nome text, p_texto text, p_papel text, p_canal text DEFAULT 'whatsapp'::text, p_chatwoot_conversation_id text DEFAULT NULL::text, p_midia jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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

  insert into public.mari_turnos (conversa_id, papel, texto, pendente, tags, midia)
  values (v_conv.id, p_papel, v_txt, false, jsonb_build_object('sem_resposta', true),
          case when p_papel = 'lead' then public._midia_ok(p_midia) end);

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
      select v.id, v.status, v.biometria_status, v.biometria_link, v.nio_pedido into v_venda
        from public.vendas v where v.id = v_conv.venda_id for update;
      if not found then
        v_capt := 'conversa sem venda no NIOGEN';
      elsif v_venda.status <> '0_qualificado' or v_venda.biometria_status = 'validada' then
        v_capt := 'venda já passou da biometria';
      elsif v_venda.biometria_link is not distinct from v_link and v_venda.biometria_status in ('pendente', 'com_risco') then
        v_capt := 'mesmo link já registrado';
      elsif coalesce(btrim(v_venda.nio_pedido), '') <> '' then
        -- 0032: o pedido já definiu a biometria (pendente) e a contagem (hora do pedido). O link colado só fica
        -- guardado como referência, se a venda ainda não tiver um; nada mais muda.
        if v_venda.biometria_link is null then
          update public.vendas set biometria_link = v_link where id = v_venda.id;
          insert into public.eventos_venda (venda_id, tipo, detalhe)
          values (v_venda.id, 'biometria_link', jsonb_build_object(
            'origem', 'chatwoot', 'conversa_id', v_conv.id, 'so_referencia', true));
          v_capt := 'link guardado (o pedido já define a contagem)';
        else
          v_capt := 'pedido já registrado (link não muda a contagem)';
        end if;
      else
        -- 0032: fallback — sem nº do pedido no NIOGEN, o link colado ainda marca a biometria pendente e a contagem.
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
$function$;

-- 4 ─ consolidar devolve a mídia
CREATE OR REPLACE FUNCTION public.mari_consolidar(p_conversa uuid, p_ts timestamp with time zone, p_ttl_seg integer DEFAULT 45)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_conv public.mari_conversas;
  v_ids  bigint[];
  v_txt  text;
  v_hist jsonb;
  v_midia jsonb;
begin
  select * into v_conv from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('resultado', 'vazio'); end if;
  if v_conv.status <> 'ativo' and not public._mari_pos_handoff(v_conv) then
    return jsonb_build_object('resultado', 'silencio', 'status', v_conv.status);
  end if;
  if v_conv.ultima_entrada_ts > p_ts then return jsonb_build_object('resultado', 'superado'); end if;
  if v_conv.processando_ate is not null and v_conv.processando_ate > now() then
    return jsonb_build_object('resultado', 'ocupado');
  end if;

  select array_agg(id order by id), string_agg(texto, E'\n' order by id)
    into v_ids, v_txt
    from public.mari_turnos where conversa_id = p_conversa and pendente;
  if v_ids is null then return jsonb_build_object('resultado', 'vazio'); end if;

  update public.mari_turnos set pendente = false where id = any (v_ids);
  update public.mari_conversas set processando_ate = now() + make_interval(secs => p_ttl_seg) where id = p_conversa;

  -- Histórico (sem as pendentes de agora), últimos 60 turnos, mais antigo primeiro.
  select coalesce(jsonb_agg(jsonb_build_object('papel', papel, 'texto', texto) order by id), '[]'::jsonb)
    into v_hist
    from (select id, papel, texto from public.mari_turnos
           where conversa_id = p_conversa and not (id = any (v_ids)) and papel in ('lead', 'mari', 'humano')
           order by id desc limit 60) t;

  -- 0145: mídia das mensagens de agora (foto vai como imagem ao Claude, pelo link curto url_ia).
  select coalesce(jsonb_agg(e order by t.id), '[]'::jsonb) into v_midia
    from public.mari_turnos t, jsonb_array_elements(coalesce(t.midia, '[]'::jsonb)) e
   where t.id = any (v_ids);

  return jsonb_build_object(
    'resultado', 'ok',
    'midia', v_midia,
    'mensagem', v_txt,
    'n_mensagens', cardinality(v_ids),
    'turno_ids', to_jsonb(v_ids),
    'historico', v_hist,
    'conversa', to_jsonb(v_conv) - 'processando_ate' - 'ultima_entrada_ts');
end;
$function$;

revoke all on function public.mari_entrada(text, text, text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.mari_entrada(text, text, text, text, text, text, jsonb) to service_role;
revoke all on function public.mari_registrar_turno(text, text, text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.mari_registrar_turno(text, text, text, text, text, text, jsonb) to service_role;
revoke all on function public.mari_consolidar(uuid, timestamptz, integer) from public, anon, authenticated;
grant execute on function public.mari_consolidar(uuid, timestamptz, integer) to service_role;

notify pgrst, 'reload schema';

commit;
