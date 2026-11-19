-- NIOGEN | supabase/migrations/0300_fila_vero_responde_todos.sql | 18/11/2026 — Claude Code / Opus 5.5
-- Ricardo, 18/11: "Se o cliente enviar qualquer mensagem pro 28880150, nada acontece. Ele é um número mudo" → "Sim, faça".
-- Até aqui o número do disparo só respondia (uma vez, com o link da oferta) a quem estava na lista, não tinha saído e escrevia
-- dentro de 24 h. Quem estava fora da lista, tinha saído, escrevia de novo ou depois de 24 h falava sozinho.
-- Agora: qualquer mensagem que não seja de saída ("Não tenho interesse", SAIR…) e que o caminho antigo não responda recebe,
-- no máximo 1 vez a cada 24 h por telefone, um texto curto com o WhatsApp da Mari. Texto livre (a pessoa escreveu primeiro,
-- janela de 24 h aberta), pelo próprio número do disparo, fora da cota do dia, também com o disparo pausado.
-- O caminho antigo (link da oferta fv.html para quem está na lista) continua igual — ele conta o clique.

begin;

create table if not exists public.fila_vero_avulsos (
  telefone      text primary key,             -- wa_id como a Meta mandou
  fila_id       bigint references public.fila_vero(id) on delete set null,
  pediu_em      timestamptz not null,          -- última mensagem que pede resposta
  respondido_em timestamptz,
  tentativas    int not null default 0,        -- falhas seguidas no envio (para em 3)
  erro          text
);
alter table public.fila_vero_avulsos enable row level security;
revoke all on public.fila_vero_avulsos from public, anon, authenticated;

insert into public.config_regras (chave, valor, descricao) values
  ('fila_vero_resposta_avulsa',
   '{"ligado":true,"intervalo_h":24,"max_rodada":30,"texto":"Oi! Este número só envia avisos e não lê as respostas. Para falar com a Mari, da Nio, é só tocar aqui: https://wa.me/553128881265"}',
   'Fila Vero (0300): resposta automática do número do disparo a quem escreve e não é atendido pelo link da oferta — 1 vez a cada intervalo_h por telefone')
on conflict (chave) do nothing;

create or replace function public.fila_vero_webhook(p_value jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s jsonb; m jsonb; v public.fila_vero%rowtype; txt text; cod text; n_s int := 0; n_m int := 0; v_sair boolean; v_de text;
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
    v_de := m ->> 'from';
    continue when coalesce(v_de, '') !~ '^\d{10,15}$';
    n_m := n_m + 1;
    txt := coalesce(m #>> '{button,text}', m #>> '{interactive,button_reply,title}', m #>> '{text,body}', '');
    v_sair := txt ~* '^\s*(n[aã]o tenho interesse|sair|parar|pare|stop|cancelar|n[aã]o quero|remover|descadastrar)\M'
              or txt ~* 'n[aã]o tenho interesse';
    v := null;
    select * into v from public.fila_vero where id = public._fila_vero_por_wa(m #>> '{context,id}', v_de);
    if v.id is not null then
      insert into public.contatos_cliente (canal, direcao, por, em, resumo, telefone, toque, tipo)
      values ('whatsapp', 'entrada', 'cliente', now(), left('Fila Vero (número do disparo): ' || txt, 300), v.telefone, 'fila_vero', 'receptivo');
      if v_sair then
        if v.status not in ('opt_out', 'ja_cliente_nio') then
          perform public.fila_vero_mudar(v.id, 'opt_out', left('cliente: ' || txt, 200), 'webhook');
        end if;
        continue;
      end if;
      update public.fila_vero set resposta_disparo_em = coalesce(resposta_disparo_em, now()) where id = v.id;
      -- o caminho antigo responde com o link da oferta? então não precisa da resposta avulsa
      continue when exists (select 1 from public.fila_vero fv where fv.id = v.id and fv.auto_resposta_em is null
                              and fv.status not in ('opt_out', 'ja_cliente_nio') and fv.resposta_disparo_em > now() - interval '24 hours');
    end if;
    continue when v_sair;
    insert into public.fila_vero_avulsos (telefone, fila_id, pediu_em) values (v_de, v.id, now())
    on conflict (telefone) do update set pediu_em = now(), fila_id = coalesce(excluded.fila_id, fila_vero_avulsos.fila_id),
      tentativas = case when fila_vero_avulsos.respondido_em is null or fila_vero_avulsos.respondido_em >= fila_vero_avulsos.pediu_em
                        then 0 else fila_vero_avulsos.tentativas end;
  end loop;
  return jsonb_build_object('status', n_s, 'mensagens', n_m);
end $$;
revoke all on function public.fila_vero_webhook(jsonb) from public, anon, authenticated;

-- quem pediu e ainda não teve a resposta avulsa (no máximo 1 a cada intervalo_h por telefone; janela de 24 h da Meta)
create or replace function public.fila_vero_avulsos_pendentes()
returns table (telefone text, texto text)
language sql stable security definer set search_path = public as $$
  with c as (select public._fv_cfg('fila_vero_resposta_avulsa') j)
  select a.telefone, c.j ->> 'texto' from public.fila_vero_avulsos a, c
   where public._os_pode_gravar() and coalesce((c.j ->> 'ligado')::boolean, false)
     and a.pediu_em > now() - interval '23 hours' and a.tentativas < 3
     and (a.respondido_em is null
          or (a.respondido_em < a.pediu_em
              and a.respondido_em < now() - make_interval(hours => coalesce((c.j ->> 'intervalo_h')::int, 24))))
   order by a.pediu_em
   limit coalesce((select (j ->> 'max_rodada')::int from c), 30);
$$;
revoke all on function public.fila_vero_avulsos_pendentes() from public, anon, authenticated;

-- resultado: itens de texto com id 'a:<telefone>' são respostas avulsas
create or replace function public.fila_vero_resultado(p_itens jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i jsonb; n_ok int := 0; n_f int := 0; v_parar text; v_cod text;
begin
  if not public._os_pode_gravar() then raise exception 'Só serviço.' using errcode = '42501'; end if;
  for i in select * from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) loop
    v_cod := nullif(i ->> 'erro_codigo', '');
    if i ->> 'tipo' = 'texto' and coalesce(i ->> 'id', '') like 'a:%' then
      if i ->> 'wamid' is not null then
        update public.fila_vero_avulsos set respondido_em = now(), tentativas = 0, erro = null where telefone = substr(i ->> 'id', 3);
      else
        update public.fila_vero_avulsos set tentativas = tentativas + 1,
               erro = left(coalesce(v_cod, '?') || ': ' || coalesce(i ->> 'erro_msg', ''), 250)
         where telefone = substr(i ->> 'id', 3);
      end if;
      continue;
    end if;
    if i ->> 'tipo' = 'texto' then
      if i ->> 'wamid' is not null then perform public.fila_vero_auto_respondida((i ->> 'id')::bigint); end if;
      continue;
    end if;
    if i ->> 'wamid' is not null then
      perform public.fila_vero_registrar_envio((i ->> 'id')::bigint, i ->> 'template', i ->> 'wamid'); n_ok := n_ok + 1;
    else
      perform public.fila_vero_registrar_falha((i ->> 'id')::bigint, i ->> 'template', coalesce(v_cod, '?'), coalesce(i ->> 'erro_msg', ''));
      n_f := n_f + 1;
      if v_cod in ('368', '131048', '131056', '130497', '80007', '131031', '132015', '132016', '131045') then
        v_parar := format('disparo pausado — a Meta devolveu o código %s (%s)', v_cod, left(coalesce(i ->> 'erro_msg', ''), 80));
      end if;
    end if;
    update public.fila_vero set reservado_em = null where id = (i ->> 'id')::bigint;
  end loop;
  if v_parar is not null then perform public.fila_vero_ligar(false, v_parar); end if;
  return jsonb_build_object('enviados', n_ok, 'falhas', n_f, 'alerta', v_parar);
end $$;
revoke all on function public.fila_vero_resultado(jsonb) from public, anon, authenticated;

create or replace function public.fila_vero_rodada(p_max int default 10)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_ritmo int; v_hoje int; v_resto int; v_rodadas int; v_quota int; v_fim time; v_l timestamp;
        itens jsonb := '[]'::jsonb; r record; n_enc int := 0; v_tpl text; v_prox_a text := public._fv_template('instalado', 1, null);
begin
  if not public._os_pode_gravar() then raise exception 'Só serviço.' using errcode = '42501'; end if;
  -- saídas automáticas (regra 20.2): 2º toque sem clique/resposta há 7 dias → encerrado
  for r in select id from public.fila_vero
            where status = 'enviado' and toques >= 2 and ultimo_toque_em < now() - interval '7 days'
              and clicou_em is null and respondeu_em is null
  loop
    perform public.fila_vero_mudar(r.id, 'encerrado', '2 toques sem resposta (D+7)', 'rodada'); n_enc := n_enc + 1;
  end loop;
  -- respostas em texto no número do disparo → link da Mari (fora da cota)
  for r in select * from public.fila_vero_auto_respostas() loop
    itens := itens || jsonb_build_object('id', r.id, 'tipo', 'texto', 'telefone', r.telefone,
      'texto', 'Oi! Quem te atende é a Mari, da nossa equipe, pelo WhatsApp da Nio. Toque no link para falar com ela agora: '
               || 'https://niogen.dharmatelecom.com.br/fv.html?t=' || coalesce(upper(substr(r.template, 8)), 'A1') || '&c=' || r.codigo
               || E'\nSe não quiser mais receber, responda SAIR.');
  end loop;
  -- 0300: qualquer outra mensagem no número do disparo → texto curto com o WhatsApp da Mari (1 vez a cada 24 h por telefone)
  for r in select * from public.fila_vero_avulsos_pendentes() loop
    itens := itens || jsonb_build_object('id', 'a:' || r.telefone, 'tipo', 'texto', 'telefone', r.telefone, 'texto', r.texto);
  end loop;
  if coalesce((public._fv_cfg('fila_vero_ativo') #>> '{}')::boolean, false) is not true or not public.fila_vero_dentro_horario() then
    return jsonb_build_object('itens', itens, 'enviar', 0, 'encerrados', n_enc, 'motivo', 'desligado ou fora do horário');
  end if;
  v_ritmo := coalesce((public._fv_cfg('fila_vero_ritmo_dia') #>> '{}')::int, 100);
  v_hoje := public._fv_enviados_hoje();
  v_resto := greatest(0, v_ritmo - v_hoje);
  v_l := now() at time zone 'America/Sao_Paulo';
  v_fim := case when extract(isodow from v_l) = 6 then coalesce((public._fv_cfg('fila_vero_horario') #>> '{sabado,1}')::time, '16:00')
                else coalesce((public._fv_cfg('fila_vero_horario') #>> '{semana,1}')::time, '21:00') end;
  v_rodadas := greatest(1, ceil(extract(epoch from (v_fim - v_l::time)) / 300.0)::int);
  v_quota := least(p_max, ceil(v_resto::numeric / v_rodadas)::int);
  for r in
    with cand as (
      select fv.*, case when fv.status = 'enviado' then 2 else 1 end as toque
        from public.fila_vero fv
       where (fv.reservado_em is null or fv.reservado_em < now() - interval '15 minutes')
         and fv.telefone ~ '^55\d{2}9\d{8}$' and fv.lugar is not null
         and length(split_part(btrim(coalesce(fv.nome, '')), ' ', 1)) >= 2
         and ((fv.status = 'apto' and fv.toques = 0
               and (fv.faixa = 'endereco' or coalesce((public._fv_cfg('fila_vero_prioridade_b') #>> '{}')::boolean, true)))
           or (fv.status = 'enviado' and fv.toques = 1 and fv.ultimo_toque_em < now() - interval '3 days'
               and fv.clicou_em is null and fv.respondeu_em is null and fv.resposta_disparo_em is null
               and coalesce(fv.meta_status, '') <> 'failed'))
         and not exists (select 1 from public.mari_conversas c
                          where c.telefone in (fv.telefone, substr(fv.telefone, 1, 4) || substr(fv.telefone, 6))))
    select * from cand
     order by toque desc, (faixa = 'endereco') desc, md5(codigo)
     limit v_quota
  loop
    update public.fila_vero set reservado_em = now() where id = r.id;
    v_tpl := public._fv_template(r.segmento, r.toque, r.template1);
    if r.segmento = 'instalado' and r.toque = 1 and (public._fv_cfg('fila_vero_ab') ->> 'vencedor') is null then
      v_tpl := v_prox_a;                                   -- A/B: alterna a1/a2 também dentro da rodada
      v_prox_a := case v_prox_a when 'nio_fv_a1' then 'nio_fv_a2' else 'nio_fv_a1' end;
    end if;
    v_tpl := public._fv_template_ok(v_tpl);              -- 0267: template com nota baixa/pausado sai do disparo
    if v_tpl is null then
      update public.fila_vero set reservado_em = null where id = r.id;
      continue;
    end if;
    itens := itens || jsonb_build_object('id', r.id, 'tipo', 'template', 'telefone', r.telefone, 'toque', r.toque,
      'template', v_tpl, 'codigo', r.codigo,
      'params', jsonb_build_array(initcap(lower(split_part(btrim(r.nome), ' ', 1))), r.lugar));
  end loop;
  return jsonb_build_object('itens', itens, 'enviar', v_quota, 'ritmo', v_ritmo, 'hoje', v_hoje, 'encerrados', n_enc);
end $$;

commit;
