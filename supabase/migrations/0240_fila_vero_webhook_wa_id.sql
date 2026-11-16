-- NIOGEN | supabase/migrations/0240_fila_vero_webhook_wa_id.sql | 16/11/2026 — Claude Code / Opus 5.5
-- Fila Vero: a Meta devolve o wa_id SEM o 9 em contas antigas (teste no número do Ricardo, 16/11: 5532988015161 → 553288015161).
-- A resposta "Não tenho interesse"/SAIR não achava a linha pelo telefone. Agora acha: 1º pela mensagem respondida
-- (context.id = wamid do template), 2º pelo telefone igual, 3º pelo telefone com o 9 inserido.
create or replace function public._fila_vero_por_wa(p_ctx text, p_from text)
returns bigint language sql stable security definer set search_path = public as $$
  select coalesce(
    (select id from public.fila_vero where p_ctx is not null and wamid = p_ctx),
    (select id from public.fila_vero where telefone = p_from),
    (select id from public.fila_vero where length(p_from) = 12 and p_from like '55%'
                                       and telefone = substr(p_from, 1, 4) || '9' || substr(p_from, 5)));
$$;

create or replace function public.fila_vero_webhook(p_value jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s jsonb; m jsonb; v public.fila_vero%rowtype; txt text; cod text; n_s int := 0; n_m int := 0;
begin
  if not public._os_pode_gravar() then raise exception 'Só serviço.' using errcode = '42501'; end if;
  if coalesce(p_value #>> '{metadata,phone_number_id}', '') <> '1124589070738034' then
    return jsonb_build_object('ignorado', 'outro número');
  end if;
  for s in select * from jsonb_array_elements(coalesce(p_value -> 'statuses', '[]')) loop
    select * into v from public.fila_vero where wamid = s ->> 'id';
    continue when v.id is null;
    n_s := n_s + 1;
    update public.fila_vero set
      meta_status = s ->> 'status',
      entregue_em = case when s ->> 'status' in ('delivered', 'read') then coalesce(entregue_em, now()) else entregue_em end,
      lido_em     = case when s ->> 'status' = 'read' then coalesce(lido_em, now()) else lido_em end
     where id = v.id;
    if s ->> 'status' = 'failed' and v.status = 'enviado' then
      cod := s #>> '{errors,0,code}';
      perform public.fila_vero_mudar(v.id, case when cod = '131050' then 'opt_out' else 'erro' end,
                                     left(format('Meta %s: %s', cod, coalesce(s #>> '{errors,0,title}', s #>> '{errors,0,message}', '')), 300),
                                     'webhook');
      update public.fila_vero set erro_codigo = cod where id = v.id;
    end if;
  end loop;
  for m in select * from jsonb_array_elements(coalesce(p_value -> 'messages', '[]')) loop
    select * into v from public.fila_vero where id = public._fila_vero_por_wa(m #>> '{context,id}', m ->> 'from');
    continue when v.id is null;
    n_m := n_m + 1;
    txt := coalesce(m #>> '{button,text}', m #>> '{interactive,button_reply,title}', m #>> '{text,body}', '');
    insert into public.contatos_cliente (canal, direcao, por, em, resumo, telefone, toque, tipo)
    values ('whatsapp', 'entrada', 'cliente', now(), left('Fila Vero (número do disparo): ' || txt, 300), v.telefone, 'fila_vero', 'receptivo');
    if txt ~* '^\s*(n[aã]o tenho interesse|sair|parar|pare|stop|cancelar|n[aã]o quero|remover|descadastrar)\M'
       or txt ~* 'n[aã]o tenho interesse' then
      if v.status not in ('opt_out', 'ja_cliente_nio') then
        perform public.fila_vero_mudar(v.id, 'opt_out', left('cliente: ' || txt, 200), 'webhook');
      end if;
    else
      update public.fila_vero set resposta_disparo_em = coalesce(resposta_disparo_em, now()) where id = v.id;
    end if;
  end loop;
  return jsonb_build_object('status', n_s, 'mensagens', n_m);
end $$;
revoke all on function public.fila_vero_webhook(jsonb), public._fila_vero_por_wa(text, text) from public, anon;
