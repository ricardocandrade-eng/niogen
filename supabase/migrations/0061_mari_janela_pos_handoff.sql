-- NIOGEN | supabase/migrations/0061_mari_janela_pos_handoff.sql | 07/11/2026 23h50 — Claude Code (pedido do Ricardo, teste real da conversa #1)
-- Por quê: depois do handoff com dados completos o cliente agradeceu ("Obrigado!") e a Mari ficou calada — o backoffice
-- ainda nem tinha pegado a conversa. Ricardo (07/11 ~23h30): "a Mari pode ficar ligada por uns 5 min após o handoff, caso
-- o cliente tenha alguma dúvida final" + responder o agradecimento ("Imagina! 💚").
-- O quê:
--   · config_mari_textos.pos_handoff_minutos = '5' (regra 15: nada fixo no código);
--   · _mari_pos_handoff(conversa): handoff dados_completos há menos de N min E nenhuma fala do nosso time desde então;
--   · mari_entrada e mari_consolidar deixam a Mari responder nessa janela (fora dela, tudo igual: silêncio).
-- O n8n (2h · Guard humano) só deixa chegar aqui a conversa com time atribuído SEM DONO e etiqueta handoff-venda; o
-- 7 · Extrair, na janela, não muda estado, não faz handoff e não manda botão. Desligar: pos_handoff_minutos = '0'.

insert into public.config_mari_textos (chave, texto)
values ('pos_handoff_minutos', '5')
on conflict (chave) do nothing;

create or replace function public._mari_pos_handoff(p_conv public.mari_conversas)
returns boolean language sql stable set search_path = public as $$
  select p_conv.status = 'handoff_realizado'
     and p_conv.handoff_motivo = 'dados_completos'
     and p_conv.handoff_em is not null
     and p_conv.handoff_em > now() - make_interval(mins => coalesce(
           (select case when texto ~ '^\d{1,3}$' then texto::int end
              from public.config_mari_textos where chave = 'pos_handoff_minutos'), 5))
     and not exists (select 1 from public.mari_turnos t
                      where t.conversa_id = p_conv.id and t.papel = 'humano' and t.created_at > p_conv.handoff_em);
$$;
comment on function public._mari_pos_handoff(public.mari_conversas) is
  'Janela pós-handoff (0061): a Mari ainda responde dúvida final/agradecimento por N min (config_mari_textos.pos_handoff_minutos) depois do handoff dados_completos, enquanto ninguém do nosso time falou.';

-- mari_entrada: igual à 0033, só muda quem fica "pendente" e o "silencio" (+ campo pos_handoff).
create or replace function public.mari_entrada(
  p_telefone text, p_nome text, p_texto text,
  p_canal text default 'teste', p_origem text default null,
  p_chatwoot_conversation_id text default null)
returns jsonb language plpgsql set search_path = public as $$
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

  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (v_conv.id, 'lead', coalesce(p_texto, ''), v_conv.status = 'ativo' or v_pos);

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
$$;

-- mari_consolidar: igual à 0013, só aceita também a janela pós-handoff.
create or replace function public.mari_consolidar(p_conversa uuid, p_ts timestamptz, p_ttl_seg int default 45)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_conv public.mari_conversas;
  v_ids  bigint[];
  v_txt  text;
  v_hist jsonb;
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

  return jsonb_build_object(
    'resultado', 'ok',
    'mensagem', v_txt,
    'n_mensagens', cardinality(v_ids),
    'turno_ids', to_jsonb(v_ids),
    'historico', v_hist,
    'conversa', to_jsonb(v_conv) - 'processando_ate' - 'ultima_entrada_ts');
end;
$$;

revoke execute on function public._mari_pos_handoff(public.mari_conversas) from public, anon, authenticated;
grant execute on function public._mari_pos_handoff(public.mari_conversas) to service_role;
