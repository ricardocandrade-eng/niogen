-- NIOGEN | supabase/migrations/0242_fila_vero_v2.sql | 16/11/2026 — Claude Code / Opus 5.5
-- Prompt docs/Prompt_fila_vero_disparo_v2_131126_1600.md (Ricardo: "Pode seguir", 16/11 ~19h10), depois do piloto (0239–0241).
-- O que entra: faixa B (bairro) e filtro de todas as cidades · disparo automático pelo n8n (fila_vero_rodada / fila_vero_resultado)
-- com horário comercial, sem domingo/feriado, cota do dia espalhada nas rodadas e reserva anti-duplicidade · 2º toque D+3 com o
-- outro gancho · encerrado D+7 depois do 2º · A/B automático (fila_vero_escolher_vencedor) · rampa +100 a cada 2 dias com teto e
-- trava de opt-out (fila_vero_rampa) · guarda de qualidade de hora em hora (fila_vero_guarda → pausa + aviso) · "não contatar" da
-- Mari vira opt-out na fila · painel agregado da tela (fila_vero_painel) e Ligar/Pausar (fila_vero_ligar) · conferência ampliada.
-- Módulo desligável (regra 15): config_regras.fila_vero_ativo = false para tudo; nada fora da fila depende disto.

alter table public.fila_vero add column if not exists template1 text;
alter table public.fila_vero add column if not exists primeiro_toque_em timestamptz;
alter table public.fila_vero add column if not exists reservado_em timestamptz;
update public.fila_vero set template1 = template, primeiro_toque_em = ultimo_toque_em
 where template is not null and template1 is null;

insert into public.config_regras (chave, valor, descricao) values
  ('fila_vero_bairro_min_cobertura', '0.6', 'Fila Vero faixa B (JF): fração mínima dos HPs do bairro com viabilidade na DFV'),
  ('fila_vero_bairro_min_hps', '20', 'Fila Vero faixa B (fora de JF, sem base de HP): mínimo de HPs cobertos do bairro na DFV'),
  ('fila_vero_pausa_qualidade', '["YELLOW", "RED"]', 'Fila Vero: qualidade do número que pausa o disparo na hora'),
  ('fila_vero_rampa', '{"passo": 100, "dias": 2, "max_optout": 0.03, "teto_pct": 0.6, "subiu_em": null, "motivo": "início (piloto 16/11)"}',
   'Fila Vero: rampa — sobe passo a cada dias se GREEN, sem aviso e opt-out < max_optout dos entregues; teto = teto_pct do limite do portfólio'),
  ('fila_vero_ab', '{"vencedor": null, "decidido_em": null, "min_envios": 200, "horas": 48}', 'Fila Vero: A/B a1 × a2 (vencedor fixado por fila_vero_escolher_vencedor)'),
  ('fila_vero_horario', '{"semana": ["09:00", "21:00"], "sabado": ["10:00", "16:00"]}', 'Fila Vero: janela do disparo (domingo e feriado: nunca)'),
  ('fila_vero_prioridade_b', 'true', 'Fila Vero: faixa B no disparo (a rampa desliga se o opt-out da B for >= 2x o da A)'),
  ('fila_vero_qualidade', '{}', 'Fila Vero: última leitura da qualidade do número do disparo (guarda de hora em hora)'),
  ('fila_vero_ativo_hist', '[]', 'Fila Vero: quem ligou/pausou o disparo, quando e por quê (últimos 30)')
on conflict (chave) do nothing;

insert into public.config_templates_waba (nome, categoria, idioma, corpo, meta_id, status, uso) values
  ('alerta_fila_vero', 'UTILITY', 'pt_BR', '⚠️ Fila Vero: {{1}}. Detalhes na tela Fila Vero do NIOGEN.', '1147819404781148', 'PENDING',
   'Aviso da Fila Vero para o Ricardo (n8n fila_vero_disparo: pausa por qualidade/política, rampa, faixa B). Interno: nunca para cliente.')
on conflict (nome) do nothing;

-- ---------------------------------------------------------------- normalização (bairro, cidade)
create or replace function public._fv_norm(p text)
returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
           ' ' || regexp_replace(upper(translate(coalesce(p, ''),
             'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ', 'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC')), '[^A-Z0-9]+', ' ', 'g') || ' ',
           ' STA ', ' SANTA ', 'g'), ' STO ', ' SANTO ', 'g'), ' N SRA ', ' NOSSA SENHORA ', 'g'), ' JD ', ' JARDIM ', 'g'),
           ' VL ', ' VILA ', 'g'), ' PQ ', ' PARQUE ', 'g'), '^ BAIRRO ', ' ')), '');
$$;

create or replace function public._fv_cidade(p text)
returns text language sql immutable as $$
  select public._fv_norm(regexp_replace(coalesce(p, ''), '\s*-\s*[A-Za-z]{2}\s*$', ''));
$$;

create or replace function public._fila_vero_lugar_bairro(p_bairro text)
returns text language sql immutable as $$
  with b as (select initcap(lower(btrim(regexp_replace(coalesce(p_bairro, ''), '\s+', ' ', 'g')))) s)
  select case when public._fv_norm(p_bairro) is null then null
              when public._fv_norm(p_bairro) = 'CENTRO' then 'no Centro'
              else 'no bairro ' || btrim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
                     ' ' || s || ' ', ' De ', ' de ', 'g'), ' Da ', ' da ', 'g'), ' Do ', ' do ', 'g'), ' Dos ', ' dos ', 'g'),
                     ' Das ', ' das ', 'g')) end
    from b;
$$;

-- ---------------------------------------------------------------- filtro completo (faixa A em JF + faixa B em todas as cidades)
create or replace function public.fila_vero_filtrar()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; a jsonb; n_b int := 0; n_cli int := 0; n_sem int := 0; n_fica int := 0; n_out int := 0;
        v_min numeric := coalesce((select (valor #>> '{}')::numeric from public.config_regras where chave = 'fila_vero_bairro_min_cobertura'), 0.6);
        v_hps int := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'fila_vero_bairro_min_hps'), 20);
begin
  if not public._os_pode_gravar() then raise exception 'Só admin ou backoffice.' using errcode = '42501'; end if;
  a := public.fila_vero_filtrar_jf();
  create temp table if not exists _fv_jf_bairro (bn text primary key, pct numeric) on commit drop;
  delete from _fv_jf_bairro;
  insert into _fv_jf_bairro
  select public._fv_norm(bairro), sum(hp_tot) filter (where viabilidade = 'Viável')::numeric / nullif(sum(hp_tot), 0)
    from public.nio_hp where municipio = 'JUIZ DE FORA' and public._fv_norm(bairro) is not null group by 1;
  for r in
    select fv.id, fv.telefone, fv.cep, fv.numero, fv.complemento, fv.bairro, public._fv_cidade(fv.cidade) as cn,
           public._fv_norm(fv.bairro) as bn,
           exists (select 1 from public.config_area ca where ca.ativo and public._fv_cidade(ca.cidade) = public._fv_cidade(fv.cidade)) as cidade_ok,
           exists (select 1 from public.vendas v
                    where v.status <> 'saida'
                      and (public.tel_e164(v.cliente_whatsapp) = '+' || fv.telefone
                           or (regexp_replace(coalesce(v.cep, ''), '\D', '', 'g') = fv.cep
                               and regexp_replace(coalesce(v.numero, ''), '\D', '', 'g') = regexp_replace(coalesce(fv.numero, ''), '\D', '', 'g')
                               and regexp_replace(coalesce(fv.numero, ''), '\D', '', 'g') <> ''))) as venda_nossa,
           exists (select 1 from public.mari_conversas c where c.telefone in (fv.telefone, substr(fv.telefone, 1, 4) || substr(fv.telefone, 6))) as conversa,
           exists (select 1 from public.mari_conversas c where c.nao_contatar
                     and c.telefone in (fv.telefone, substr(fv.telefone, 1, 4) || substr(fv.telefone, 6))) as nao_contatar
      from public.fila_vero fv
     where fv.status = 'novo'
       and coalesce(fv.motivo, '') not in ('já conversa com a Mari', 'prédio com cliente Nio: conferir unidade (v2)')
  loop
    if r.nao_contatar then
      perform public.fila_vero_mudar(r.id, 'opt_out', 'não contatar (Mari)', 'filtro'); n_out := n_out + 1;
    elsif not r.cidade_ok then
      perform public.fila_vero_mudar(r.id, 'sem_cobertura', 'cidade fora das cidades da Nio', 'filtro'); n_sem := n_sem + 1;
    elsif r.venda_nossa then
      perform public.fila_vero_mudar(r.id, 'ja_cliente_nio', 'venda Nio no mesmo telefone ou endereço', 'filtro'); n_cli := n_cli + 1;
    elsif r.conversa then
      update public.fila_vero set motivo = 'já conversa com a Mari' where id = r.id; n_fica := n_fica + 1;
    elsif r.bn is null then
      perform public.fila_vero_mudar(r.id, 'sem_cobertura', 'sem bairro na base', 'filtro'); n_sem := n_sem + 1;
    elsif r.cn = 'JUIZ DE FORA' then
      if coalesce((select pct from _fv_jf_bairro where bn = r.bn), 0) >= v_min then
        update public.fila_vero set faixa = 'bairro', lugar = public._fila_vero_lugar_bairro(r.bairro) where id = r.id;
        perform public.fila_vero_mudar(r.id, 'apto', format('DFV: bairro com %s%% dos HPs viáveis',
                round(100 * (select pct from _fv_jf_bairro where bn = r.bn))), 'filtro'); n_b := n_b + 1;
      else
        perform public.fila_vero_mudar(r.id, 'sem_cobertura', format('DFV: bairro com %s%% dos HPs viáveis (mínimo %s%%)',
                coalesce(round(100 * (select pct from _fv_jf_bairro where bn = r.bn)), 0), round(100 * v_min)), 'filtro'); n_sem := n_sem + 1;
      end if;
    elsif exists (select 1 from public.dfv_cobertura_bairro d
                   where public._fv_cidade(d.municipio) = r.cn and public._fv_norm(d.bairro) = r.bn and d.hps >= v_hps) then
      update public.fila_vero set faixa = 'bairro', lugar = public._fila_vero_lugar_bairro(r.bairro) where id = r.id;
      perform public.fila_vero_mudar(r.id, 'apto', 'DFV: bairro com cobertura', 'filtro'); n_b := n_b + 1;
    else
      perform public.fila_vero_mudar(r.id, 'sem_cobertura', 'DFV: bairro sem cobertura', 'filtro'); n_sem := n_sem + 1;
    end if;
  end loop;
  return a || jsonb_build_object('faixa_b_apto', n_b, 'b_ja_cliente', n_cli, 'b_sem_cobertura', n_sem, 'b_segue_novo', n_fica, 'b_opt_out', n_out);
end $$;

-- ---------------------------------------------------------------- janela e cota
create or replace function public.fila_vero_dentro_horario(p_agora timestamptz default now())
returns boolean language sql stable security definer set search_path = public as $$
  with t as (select (p_agora at time zone 'America/Sao_Paulo') l),
       h as (select coalesce((select valor from public.config_regras where chave = 'fila_vero_horario'), '{}'::jsonb) v)
  select case
           when exists (select 1 from public.config_feriados f, t where f.data = t.l::date) then false
           when extract(isodow from t.l) = 7 then false
           when extract(isodow from t.l) = 6 then t.l::time >= coalesce((h.v #>> '{sabado,0}')::time, '10:00') and t.l::time < coalesce((h.v #>> '{sabado,1}')::time, '16:00')
           else t.l::time >= coalesce((h.v #>> '{semana,0}')::time, '09:00') and t.l::time < coalesce((h.v #>> '{semana,1}')::time, '21:00')
         end
    from t, h;
$$;

create or replace function public._fv_enviados_hoje()
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.contatos_cliente
   where toque = 'fila_vero' and direcao = 'saida'
     and (em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date;
$$;

create or replace function public._fv_cfg(p_chave text)
returns jsonb language sql stable security definer set search_path = public as $$
  select valor from public.config_regras where chave = p_chave;
$$;

create or replace function public._fv_cfg_set(p_chave text, p_valor jsonb)
returns void language sql security definer set search_path = public as $$
  update public.config_regras set valor = p_valor, atualizado_em = now() where chave = p_chave;
$$;

-- ---------------------------------------------------------------- ligar / pausar (regra 20.3: motivo e autor)
create or replace function public.fila_vero_ligar(p_ligar boolean, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_autor text;
begin
  if not (public.meu_perfil() = 'admin' or session_user <> 'authenticator'
          or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') = 'service_role') then
    raise exception 'Só admin liga ou pausa a Fila Vero.' using errcode = '42501';
  end if;
  v_autor := coalesce((select nome from public.usuarios where id = auth.uid()), 'sistema');
  perform public._fv_cfg_set('fila_vero_ativo', to_jsonb(p_ligar));
  perform public._fv_cfg_set('fila_vero_ativo_hist',
    (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from (
       select x, o from (
         select jsonb_build_object('ativo', p_ligar, 'por', v_autor, 'em', now(), 'motivo', coalesce(p_motivo, case when p_ligar then 'ligado' else 'pausado' end)) x, 0::bigint o
         union all
         select e.x, e.o from jsonb_array_elements(coalesce(public._fv_cfg('fila_vero_ativo_hist'), '[]'::jsonb)) with ordinality e(x, o)) u
       order by o limit 30) h));
  return jsonb_build_object('ativo', p_ligar);
end $$;

-- ---------------------------------------------------------------- template do toque (A/B e 2º toque)
create or replace function public._fv_template(p_segmento text, p_toque int, p_template1 text)
returns text language sql stable security definer set search_path = public as $$
  select case
    when p_segmento <> 'instalado' then 'nio_fv_b1'
    when p_toque = 2 then case p_template1 when 'nio_fv_a1' then 'nio_fv_a2' when 'nio_fv_a2' then 'nio_fv_a1' else 'nio_fv_b1' end
    when (public._fv_cfg('fila_vero_ab') ->> 'vencedor') is not null then public._fv_cfg('fila_vero_ab') ->> 'vencedor'
    when (select count(*) filter (where template1 = 'nio_fv_a1') from public.fila_vero)
       <= (select count(*) filter (where template1 = 'nio_fv_a2') from public.fila_vero) then 'nio_fv_a1'
    else 'nio_fv_a2' end;
$$;

-- ---------------------------------------------------------------- rodada do n8n (a cada 5 min)
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
    itens := itens || jsonb_build_object('id', r.id, 'tipo', 'template', 'telefone', r.telefone, 'toque', r.toque,
      'template', v_tpl, 'codigo', r.codigo,
      'params', jsonb_build_array(initcap(lower(split_part(btrim(r.nome), ' ', 1))), r.lugar));
  end loop;
  return jsonb_build_object('itens', itens, 'enviar', v_quota, 'ritmo', v_ritmo, 'hoje', v_hoje, 'encerrados', n_enc);
end $$;

-- resultado dos envios da rodada (n8n): [{id, tipo, template, wamid, erro_codigo, erro_msg}]
create or replace function public.fila_vero_resultado(p_itens jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i jsonb; n_ok int := 0; n_f int := 0; v_parar text; v_cod text;
begin
  if not public._os_pode_gravar() then raise exception 'Só serviço.' using errcode = '42501'; end if;
  for i in select * from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) loop
    v_cod := nullif(i ->> 'erro_codigo', '');
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

-- envio: 1º toque guarda template1/primeiro_toque_em; 2º toque grava o evento (o status já é 'enviado')
create or replace function public.fila_vero_registrar_envio(p_id bigint, p_template text, p_wamid text)
returns void language plpgsql security definer set search_path = public as $$
declare v public.fila_vero%rowtype;
begin
  if not public._os_pode_gravar() then raise exception 'Só admin ou backoffice.' using errcode = '42501'; end if;
  update public.fila_vero set toques = toques + 1, ultimo_toque_em = now(), template = p_template, wamid = p_wamid,
         meta_status = 'accepted', entregue_em = null, lido_em = null,
         template1 = coalesce(template1, p_template), primeiro_toque_em = coalesce(primeiro_toque_em, now()), reservado_em = null
   where id = p_id returning * into v;
  insert into public.contatos_cliente (canal, direcao, por, em, resumo, telefone, toque, tipo)
  values ('whatsapp', 'saida', 'mari', now(), 'Fila Vero: template ' || p_template || case when v.toques = 2 then ' (2º toque)' else '' end,
          v.telefone, 'fila_vero', 'ativo');
  if v.toques >= 2 then
    insert into public.fila_vero_eventos (parceiro_id, fila_id, de, para, motivo, autor)
    values (v.parceiro_id, v.id, 'enviado', 'enviado', '2º toque: template ' || p_template, 'rodada');
    update public.fila_vero set prazo = now() + interval '7 days' where id = p_id;   -- D+7 → encerrado
  else
    perform public.fila_vero_mudar(p_id, 'enviado', 'template ' || p_template, 'rodada');
  end if;
end $$;

-- ---------------------------------------------------------------- A/B
create or replace function public.fila_vero_escolher_vencedor()
returns jsonb language plpgsql security definer set search_path = public as $$
declare ab jsonb := public._fv_cfg('fila_vero_ab'); v_n int; v_ult timestamptz; s1 numeric; s2 numeric; v_venc text;
begin
  if not public._os_pode_gravar() then raise exception 'Só serviço.' using errcode = '42501'; end if;
  if ab ->> 'vencedor' is not null then return ab; end if;
  select count(*), max(primeiro_toque_em) into v_n, v_ult from (
    select primeiro_toque_em from public.fila_vero where template1 in ('nio_fv_a1', 'nio_fv_a2')
     order by primeiro_toque_em limit coalesce((ab ->> 'min_envios')::int, 200)) x;
  if v_n < coalesce((ab ->> 'min_envios')::int, 200) or v_ult > now() - make_interval(hours => coalesce((ab ->> 'horas')::int, 48)) then
    return ab || jsonb_build_object('falta', format('%s de %s envios; decide %s h depois do último', v_n, coalesce((ab ->> 'min_envios')::int, 200), coalesce((ab ->> 'horas')::int, 48)));
  end if;
  select (count(*) filter (where clicou_em is not null or conversa_id is not null or resposta_disparo_em is not null))::numeric / nullif(count(entregue_em), 0)
    into s1 from public.fila_vero where template1 = 'nio_fv_a1';
  select (count(*) filter (where clicou_em is not null or conversa_id is not null or resposta_disparo_em is not null))::numeric / nullif(count(entregue_em), 0)
    into s2 from public.fila_vero where template1 = 'nio_fv_a2';
  v_venc := case when coalesce(s2, 0) > coalesce(s1, 0) then 'nio_fv_a2' else 'nio_fv_a1' end;
  ab := ab || jsonb_build_object('vencedor', v_venc, 'decidido_em', now(), 'taxa_a1', round(coalesce(s1, 0), 4), 'taxa_a2', round(coalesce(s2, 0), 4));
  perform public._fv_cfg_set('fila_vero_ab', ab);
  return ab;
end $$;

-- ---------------------------------------------------------------- rampa (1x por dia, chamada pela guarda)
create or replace function public.fila_vero_rampa()
returns jsonb language plpgsql security definer set search_path = public as $$
declare rp jsonb := public._fv_cfg('fila_vero_rampa'); q jsonb := public._fv_cfg('fila_vero_qualidade');
        v_ritmo int := coalesce((public._fv_cfg('fila_vero_ritmo_dia') #>> '{}')::int, 100);
        v_lim int; v_teto int; v_ent int; v_opt int; v_tx numeric; v_txa numeric; v_txb numeric; v_entb int; v_novo int; v_motivo text;
begin
  if not public._os_pode_gravar() then raise exception 'Só serviço.' using errcode = '42501'; end if;
  v_lim := case q ->> 'tier' when 'TIER_250' then 250 when 'TIER_1K' then 1000 when 'TIER_2K' then 2000 when 'TIER_10K' then 10000
                              when 'TIER_100K' then 100000 when 'TIER_UNLIMITED' then 100000 else 250 end;
  v_teto := floor(v_lim * coalesce((rp ->> 'teto_pct')::numeric, 0.6));
  select count(entregue_em), count(*) filter (where status = 'opt_out' and toques > 0) into v_ent, v_opt from public.fila_vero;
  v_tx := v_opt::numeric / nullif(v_ent, 0);
  select (count(*) filter (where status = 'opt_out' and toques > 0))::numeric / nullif(count(entregue_em), 0) into v_txa from public.fila_vero where faixa = 'endereco';
  select (count(*) filter (where status = 'opt_out' and toques > 0))::numeric / nullif(count(entregue_em), 0), count(entregue_em) into v_txb, v_entb from public.fila_vero where faixa = 'bairro';
  -- faixa B rende 2x mais opt-out que a A (com 50+ entregues) → sai do disparo e avisa
  if v_entb >= 50 and coalesce(v_txa, 0) > 0 and v_txb >= 2 * v_txa
     and coalesce((public._fv_cfg('fila_vero_prioridade_b') #>> '{}')::boolean, true) then
    perform public._fv_cfg_set('fila_vero_prioridade_b', 'false');
    rp := rp || jsonb_build_object('alerta', format('faixa B (bairro) fora do disparo: opt-out %s%% contra %s%% da faixa A', round(100 * v_txb, 1), round(100 * v_txa, 1)));
  end if;
  if (rp ->> 'subiu_em') is not null and (rp ->> 'subiu_em')::timestamptz > now() - make_interval(days => coalesce((rp ->> 'dias')::int, 2)) then
    return rp || jsonb_build_object('ritmo', v_ritmo, 'teto', v_teto, 'optout', round(coalesce(v_tx, 0), 4));
  end if;
  if coalesce(q ->> 'rating', '') <> 'GREEN' then
    v_motivo := 'não subiu: qualidade ' || coalesce(q ->> 'rating', 'sem leitura');
  elsif coalesce(v_tx, 0) >= coalesce((rp ->> 'max_optout')::numeric, 0.03) then
    v_motivo := format('não subiu: opt-out %s%% dos entregues (máximo %s%%)', round(100 * coalesce(v_tx, 0), 1), round(100 * coalesce((rp ->> 'max_optout')::numeric, 0.03), 1));
  elsif v_ritmo >= v_teto then
    v_motivo := format('no teto: %s/dia (%s%% do limite %s)', v_teto, round(100 * coalesce((rp ->> 'teto_pct')::numeric, 0.6)), v_lim);
  else
    v_novo := least(v_teto, v_ritmo + coalesce((rp ->> 'passo')::int, 100));
    perform public._fv_cfg_set('fila_vero_ritmo_dia', to_jsonb(v_novo));
    v_motivo := format('subiu de %s para %s/dia (GREEN, opt-out %s%%)', v_ritmo, v_novo, round(100 * coalesce(v_tx, 0), 1));
    v_ritmo := v_novo;
  end if;
  rp := rp || jsonb_build_object('subiu_em', case when v_novo is not null then now() else (rp ->> 'subiu_em')::timestamptz end,
                                 'motivo', v_motivo, 'avaliado_em', now(), 'ritmo', v_ritmo, 'teto', v_teto, 'optout', round(coalesce(v_tx, 0), 4));
  perform public._fv_cfg_set('fila_vero_rampa', rp - 'alerta');
  return rp;
end $$;

-- ---------------------------------------------------------------- guarda do número (n8n, de hora em hora)
create or replace function public.fila_vero_guarda(p_leitura jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_rating text := p_leitura ->> 'quality_rating'; v_status text := p_leitura ->> 'status'; v_alerta text; rp jsonb; v_hora int;
begin
  if not public._os_pode_gravar() then raise exception 'Só serviço.' using errcode = '42501'; end if;
  perform public._fv_cfg_set('fila_vero_qualidade', jsonb_build_object('rating', v_rating, 'status', v_status,
    'tier', coalesce(p_leitura ->> 'whatsapp_business_manager_messaging_limit', p_leitura ->> 'messaging_limit_tier'),
    'nome', p_leitura ->> 'verified_name', 'nome_status', p_leitura ->> 'name_status', 'em', now()));
  if (v_rating is not null and public._fv_cfg('fila_vero_pausa_qualidade') ? v_rating) or coalesce(v_status, 'CONNECTED') not in ('CONNECTED') then
    if coalesce((public._fv_cfg('fila_vero_ativo') #>> '{}')::boolean, false) then
      v_alerta := format('disparo pausado — qualidade do número %s, status %s', coalesce(v_rating, '?'), coalesce(v_status, '?'));
      perform public.fila_vero_ligar(false, v_alerta);
    end if;
  end if;
  perform public.fila_vero_escolher_vencedor();
  v_hora := extract(hour from now() at time zone 'America/Sao_Paulo');
  if v_hora = 8 then   -- rampa e faixa B: 1x por dia, antes da janela abrir
    rp := public.fila_vero_rampa();
    v_alerta := coalesce(v_alerta, rp ->> 'alerta');
  end if;
  return jsonb_build_object('alerta', v_alerta, 'rating', v_rating);
end $$;

-- ---------------------------------------------------------------- "não contatar" da Mari → opt-out na fila
create or replace function public._fila_vero_nao_contatar()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  begin
    v_id := public._fila_vero_por_wa(null, new.telefone);
    if v_id is not null and (select status from public.fila_vero where id = v_id) not in ('opt_out', 'ja_cliente_nio') then
      perform set_config('niogen.fila_vero_porta', 'on', true);
      perform set_config('niogen.fila_vero_motivo', 'não contatar marcado na Mari', true);
      perform set_config('niogen.fila_vero_autor', 'mari_conversas', true);
      update public.fila_vero set status = 'opt_out', motivo = 'não contatar marcado na Mari' where id = v_id;
      perform set_config('niogen.fila_vero_porta', 'off', true);
    end if;
  exception when others then
    raise warning 'fila_vero_nao_contatar: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists mari_conversas_fila_vero_nao_contatar on public.mari_conversas;
create trigger mari_conversas_fila_vero_nao_contatar after update of nao_contatar on public.mari_conversas
  for each row when (new.nao_contatar and not coalesce(old.nao_contatar, false))
  execute function public._fila_vero_nao_contatar();
-- acerto: quem já está em não contatar
do $$ declare r record; begin
  for r in select fv.id from public.fila_vero fv join public.mari_conversas c
             on c.telefone in (fv.telefone, substr(fv.telefone, 1, 4) || substr(fv.telefone, 6))
            where c.nao_contatar and fv.status not in ('opt_out', 'ja_cliente_nio') loop
    perform public.fila_vero_mudar(r.id, 'opt_out', 'não contatar (Mari)', 'migration 0242');
  end loop;
end $$;

-- ---------------------------------------------------------------- painel da tela (uma RPC agregada — regra 19)
create or replace function public.fila_vero_painel()
returns jsonb language sql stable security definer set search_path = public as $$
  with f as (select fv.*, c.funil_etapa, c.venda_id as cvenda from public.fila_vero fv left join public.mari_conversas c on c.id = fv.conversa_id),
  v as (select f.template1, f.faixa, vd.status, vd.comissao_prevista from f join public.vendas vd on vd.id = coalesce(f.venda_id, f.cvenda)),
  tp as (select template1 t, count(*) enviados, count(entregue_em) entregues, count(lido_em) lidos, count(clicou_em) cliques,
                count(conversa_id) na_mari, count(*) filter (where status = 'opt_out') opt_out,
                count(*) filter (where funil_etapa in ('qualificada', 'pedido', 'biometria', 'agendada', 'instalada')) qualificados
           from f where template1 is not null group by 1),
  fx as (select faixa, count(*) filter (where status = 'apto') aptos, count(*) filter (where toques > 0) enviados, count(entregue_em) entregues,
                count(clicou_em) cliques, count(conversa_id) na_mari, count(*) filter (where status = 'opt_out' and toques > 0) opt_out
           from f where faixa is not null group by 1)
  select jsonb_build_object(
    'ativo', coalesce((public._fv_cfg('fila_vero_ativo') #>> '{}')::boolean, false),
    'dentro_horario', public.fila_vero_dentro_horario(),
    'ritmo', coalesce((public._fv_cfg('fila_vero_ritmo_dia') #>> '{}')::int, 100),
    'hoje', public._fv_enviados_hoje(),
    'rampa', public._fv_cfg('fila_vero_rampa'),
    'ab', public._fv_cfg('fila_vero_ab'),
    'qualidade', public._fv_cfg('fila_vero_qualidade'),
    'prioridade_b', public._fv_cfg('fila_vero_prioridade_b'),
    'hist', public._fv_cfg('fila_vero_ativo_hist'),
    'base', (select count(*) from f),
    'por_status', (select jsonb_object_agg(status, n) from (select status, count(*) n from f group by 1) s),
    'enviados', (select count(*) from f where toques > 0),
    'segundo_toque', (select count(*) from f where toques >= 2),
    'entregues', (select count(entregue_em) from f),
    'lidos', (select count(lido_em) from f),
    'cliques', (select count(clicou_em) from f),
    'na_mari', (select count(conversa_id) from f),
    'qualificados', (select count(*) from f where funil_etapa in ('qualificada', 'pedido', 'biometria', 'agendada', 'instalada')),
    'pedidos', (select count(*) from f where funil_etapa in ('pedido', 'biometria', 'agendada', 'instalada')),
    'instaladas', (select count(*) from v where status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')),
    'comissao', (select coalesce(sum(comissao_prevista), 0) from v where status <> 'saida'),
    'opt_out', (select count(*) from f where status = 'opt_out' and toques > 0),
    'por_template', (select coalesce(jsonb_object_agg(t, to_jsonb(tp) - 't'), '{}'::jsonb) from tp),
    'por_faixa', (select coalesce(jsonb_object_agg(faixa, to_jsonb(fx) - 'faixa'), '{}'::jsonb) from fx),
    'falhas', (select coalesce(jsonb_object_agg(coalesce(erro_codigo, '?'), n), '{}'::jsonb) from (select erro_codigo, count(*) n from f where erro_codigo is not null group by 1) e),
    'clicou_sem_mari', (select coalesce(jsonb_agg(x order by x ->> 'clicou_em' desc), '[]'::jsonb) from (
        select jsonb_build_object('id', id, 'nome', initcap(lower(split_part(btrim(coalesce(nome, '')), ' ', 1))), 'telefone', telefone,
                                  'template', template1, 'clicou_em', clicou_em, 'lugar', lugar) x
          from f where clicou_em is not null and conversa_id is null and clicou_em < now() - interval '2 hours'
           and status not in ('opt_out', 'ja_cliente_nio') order by clicou_em desc limit 30) c),
    'em', now())
  where public.meu_perfil() in ('admin', 'backoffice') or session_user <> 'authenticator';
$$;

revoke all on function public.fila_vero_filtrar(), public.fila_vero_rodada(int), public.fila_vero_resultado(jsonb),
  public.fila_vero_escolher_vencedor(), public.fila_vero_rampa(), public.fila_vero_guarda(jsonb),
  public._fv_cfg_set(text, jsonb), public.fila_vero_ligar(boolean, text), public.fila_vero_painel() from public, anon;
grant execute on function public.fila_vero_ligar(boolean, text), public.fila_vero_painel(), public.fila_vero_filtrar() to authenticated;

-- ---------------------------------------------------------------- conferência (regra 20.5): cota do dia e apto parado
CREATE OR REPLACE FUNCTION public.conferencia_itens(p_parceiro text DEFAULT 'dharma'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  it     jsonb := '[]'::jsonb;
  n      int;
  n2     int;
  ex     text;
  v_tot  int;
  v_soma int;
begin
  if not public._os_pode_gravar() then   -- admin, backoffice, chave de serviço ou CLI
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;

  -- 1. A soma dos destinos é o total de leads
  select count(*) into v_tot from public.v_leads;
  select coalesce(sum(c), 0) into v_soma from (select count(*) c from public.v_leads where destino is not null group by destino) x;
  it := it || jsonb_build_object('codigo', 'soma_destinos', 'nome', 'Soma dos destinos = total de leads',
    'nivel', case when v_tot = v_soma then 'ok' else 'falha' end, 'n', v_tot - v_soma,
    'texto', format('%s leads; os destinos somam %s', v_tot, v_soma),
    'fazer', case when v_tot = v_soma then null else 'Há lead sem destino: avisar o Claude Code (é defeito da v_leads).' end);

  -- 2. Lead em andamento sem vez / sem status · saída sem motivo
  select count(*), string_agg(nome, ', ' order by ultima_em desc) filter (where rn <= 5) into n, ex
    from (select nome, ultima_em, row_number() over (order by ultima_em desc) rn from public.v_leads
           where destino = 'em_andamento' and (vez is null or status is null)) x;
  it := it || jsonb_build_object('codigo', 'lead_sem_vez', 'nome', 'Todo lead em andamento tem status e vez',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todos com status e de quem é a vez' else format('%s lead(s) sem status ou sem vez: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Abrir cada um na Leads e registrar o que falta; se o sistema não deixar, avisar o Claude Code.' end);

  select count(*), string_agg(nome, ', ' order by ultima_em desc) filter (where rn <= 5) into n, ex
    from (select nome, ultima_em, row_number() over (order by ultima_em desc) rn from public.v_leads
           where destino = 'saida' and saida_motivo is null) x;
  it := it || jsonb_build_object('codigo', 'saida_sem_motivo', 'nome', 'Toda saída tem motivo',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as saídas com motivo da lista única' else format('%s saída(s) sem motivo: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Abrir a ficha e registrar o motivo da Saída.' end);

  -- 3. Prazo vencido (ninguém parado em silêncio): fecha, mas é para olhar hoje
  select count(*) into n from public.v_leads where destino = 'em_andamento' and atrasado and not em_espera;
  it := it || jsonb_build_object('codigo', 'atrasados', 'nome', 'Leads com o prazo da vez vencido',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum lead com prazo vencido' else format('%s lead(s) com o prazo vencido', n) end,
    'fazer', case when n = 0 then null else 'Leads › aba Precisam de ação.' end);

  -- 4. NIOGEN × Nio — venda sem pedido
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') filter (where rn <= 5) into n, ex
    from (select cliente_nome, row_number() over (order by criado_em desc) rn from public.vendas
           where status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio')
             and coalesce(nullif(btrim(nio_os), ''), nullif(btrim(nio_pedido), '')) is null) x;
  it := it || jsonb_build_object('codigo', 'venda_sem_pedido', 'nome', 'Toda venda tem o nº do pedido da Nio',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as vendas com pedido' else format('%s venda(s) sem nº de pedido: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Gravar o nº do pedido do portal na ficha.' end);

  -- 5. NIOGEN × Nio — OS aberta que o Operador de OS nunca leu (há mais de 6 h)
  select count(*), string_agg(ped, ', ') filter (where rn <= 5) into n, ex
    from (select coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) as ped,
                 row_number() over (order by v.criado_em desc) rn
            from public.vendas v
           where v.status in ('1_vendido', '2_aguardando_instalacao')
             and coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) ~ '^\d{8}$'
             and coalesce(v.nio_os_em, v.nio_pedido_em, v.vendido_em, v.criado_em) < now() - interval '6 hours'
             and not exists (select 1 from public.os_andamento a where a.parceiro_id = p_parceiro
                              and a.pedido = coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')))) x;
  it := it || jsonb_build_object('codigo', 'os_sem_leitura', 'nome', 'Toda OS aberta foi lida na Nio',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as OS abertas com leitura do Operador de OS' else format('%s OS sem nenhuma leitura: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Operações › ⟳ Varrer OS abertas. Se não ler, conferir o CPF e o nº da OS da venda.' end);

  -- 6. NIOGEN × Nio — a Nio enxerga pedido que o NIOGEN não tem
  select count(*) into n from public.portal_pedidos p
   where p.parceiro_id = p_parceiro and p.venda_id is null and upper(coalesce(p.tipo, '')) = 'VENDA'
     and p.ultima_leitura > now() - interval '30 days';
  select coalesce((i.resumo ->> 'sem_venda')::int, 0) into n2 from public.importacoes i
   where i.tipo = 'osab' and i.aplicado_em is not null order by i.aplicado_em desc limit 1;
  it := it || jsonb_build_object('codigo', 'pedido_sem_venda', 'nome', 'Pedido na Nio sem venda no NIOGEN',
    'nivel', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then 'ok' else 'atencao' end, 'n', coalesce(n, 0) + coalesce(n2, 0),
    'texto', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then 'nenhum pedido da Nio sem venda nossa'
                  else format('%s no Histórico do portal e %s no último OSAB', coalesce(n, 0), coalesce(n2, 0)) end,
    'fazer', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then null else 'Live › Conferir › casar o pedido com a venda (ou registrar a venda que falta).' end);

  -- 7. NIOGEN × Nio — texto novo da Nio sem tradução e exceção de OS parada há mais de 1 dia
  select count(*), string_agg(texto, ' · ') into n, ex from public.config_os_estados where parceiro_id = p_parceiro and estado is null;
  it := it || jsonb_build_object('codigo', 'os_texto_novo', 'nome', 'Textos da Nio traduzidos',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'todos os textos da OS conhecidos' else format('%s texto(s) sem tradução: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Avisar o Ricardo para traduzir (config_os_estados). Enquanto isso a venda não muda sozinha.' end);

  select count(*) into n from public.os_andamento where parceiro_id = p_parceiro and excecao and excecao_desde < now() - interval '1 day';
  it := it || jsonb_build_object('codigo', 'os_excecao_parada', 'nome', 'Exceção de OS tratada no mesmo dia',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma exceção de OS aberta há mais de 1 dia' else format('%s exceção(ões) de OS aberta(s) há mais de 1 dia', n) end,
    'fazer', case when n = 0 then null else 'Live › Conferir › linhas "OS … na Nio".' end);

  -- 8. NIOGEN × Chatwoot — conversa mexida fora e ação que o Chatwoot não obedeceu
  select count(*) into n from public.mari_conversas c
   where c.canal = 'whatsapp' and c.funil_alerta is not null and coalesce(c.telefone, '') not like '5500000000%';
  select count(*) into n2 from public.chatwoot_acoes a
   where a.status = 'erro' and a.criada_em > now() - interval '7 days'
     and not exists (select 1 from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.tipo = a.tipo
                       and b.status = 'feita' and b.criada_em > a.criada_em);
  it := it || jsonb_build_object('codigo', 'chatwoot', 'nome', 'NIOGEN e Chatwoot dizem a mesma coisa',
    'nivel', case when n + n2 = 0 then 'ok' else 'atencao' end, 'n', n + n2,
    'texto', case when n + n2 = 0 then 'nenhuma conversa mexida fora e nenhuma ação em erro'
                  else format('%s conversa(s) mexida(s) direto no Chatwoot · %s ação(ões) que o Chatwoot não obedeceu', n, n2) end,
    'fazer', case when n + n2 = 0 then null else 'Live › Conferir.' end);

  -- 9. Dinheiro — toda instalada tem a comissão prevista lançada
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') filter (where rn <= 5) into n, ex
    from (select v.cliente_nome, row_number() over (order by v.instalado_em desc) rn from public.vendas v
           where v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') and v.instalado_em is not null
             and coalesce(v.comissao_prevista, 0) > 0
             and not exists (select 1 from public.comissao_lancamentos l where l.venda_id = v.id and l.tipo = 'prevista')) x;
  it := it || jsonb_build_object('codigo', 'instalada_sem_previsto', 'nome', 'Toda instalada tem a comissão prevista lançada',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as instaladas com o previsto na razão da comissão' else format('%s instalada(s) sem o previsto: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: a razão da comissão não lançou o previsto.' end);

  -- 10. Dinheiro — previsto × extrato (só quando houver Extrato importado e conciliado: etapa 5c)
  select count(*) into n from public.comissao_lancamentos where parceiro_id = p_parceiro and origem = 'extrato';
  it := it || jsonb_build_object('codigo', 'previsto_extrato', 'nome', 'Comissão prevista × Extrato da Nio',
    'nivel', case when n = 0 then 'sem_dado' else 'ok' end, 'n', n,
    'texto', case when n = 0 then 'o Extrato da Nio ainda não foi conciliado (etapa 5c do plano)' else format('%s lançamento(s) do extrato', n) end,
    'fazer', null);

  -- 11. 0182 — risco de recompra: venda em andamento com CPF ou endereço repetido e ainda sem o "Conferi" (só aviso)
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') into n, ex from public.v_venda_risco_recompra;
  it := it || jsonb_build_object('codigo', 'risco_recompra', 'nome', 'Venda em andamento sem risco de recompra',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma venda em andamento com CPF ou endereço repetido' else format('%s venda(s) com CPF ou endereço repetido: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Conferir no portal antes de gravar o pedido e marcar "Conferi" na ficha. Recompra = multa de R$ 500.' end);

  -- 12. 0183 — o vermelho do pulso tem dono: incidente "Mari parada" sem nenhum cliente esperando (últimas 24 h; sem crédito não conta)
  select count(*), string_agg(to_char(inicio_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), ', ' order by inicio_em) into n, ex
    from public.pulso_incidentes
   where parceiro_id = p_parceiro and elo = 'mari' and nivel = 'parado' and clientes_esperando_max = 0
     and inicio_em > now() - interval '24 hours' and coalesce(motivo, '') not ilike 'sem crédito%';
  it := it || jsonb_build_object('codigo', 'pulso_mari_sem_espera', 'nome', 'Alarme da Mari só com cliente esperando',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum alarme vermelho da Mari sem cliente esperando nas últimas 24 h'
                  else format('%s alarme(s) vermelho(s) da Mari sem cliente esperando: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: o pulso acusou a Mari sem ninguém esperando (ver pulso_incidentes e Mari › Erros).' end);

  -- 13. 0186 — o caminho de volta para a Meta: evento na fila com erro, ou venda de anuncio cuja OS nao virou Purchase enviado
  select count(*), string_agg(distinct evento, ', ') into n, ex from public.meta_eventos
   where parceiro_id = p_parceiro and status = 'erro';
  -- só conta o que já passou de 1 h: a fila normal esvazia de 5 em 5 min
  select count(*) into n2 from public.v_venda_meta vm
   where vm.tem_os and vm.meta_status = 'sem_evento'
      or (vm.tem_os and vm.meta_status = 'pendente'
          and exists (select 1 from public.meta_eventos e where e.venda_id = vm.venda_id and e.evento = 'Purchase'
                        and e.criado_em < now() - interval '1 hour'));
  it := it || jsonb_build_object('codigo', 'meta_capi', 'nome', 'A Meta recebeu o que o NIOGEN gravou',
    'nivel', case when n > 0 then 'falha' when n2 > 0 then 'atencao' else 'ok' end, 'n', n + n2,
    'texto', case when n > 0 then format('%s evento(s) com erro de envio (%s)', n, left(coalesce(ex, ''), 60))
                  when n2 > 0 then format('%s venda(s) de anuncio esperando o Purchase na fila', n2)
                  else 'nenhum erro de envio e nenhuma venda de anuncio parada na fila' end,
    'fazer', case when n > 0 then 'Avisar o Claude Code: ver meta_eventos (resposta e fbtrace_id) e o workflow meta_capi_envio. Nao reenviar a mao.'
                  when n2 > 0 then 'Se passar de 1 h, o workflow meta_capi_envio pode estar parado: avisar o Claude Code.'
                  else null end);


  -- 14. 0202 — conferir a rua: o portal consultou outra rua e ninguém conferiu em 4 h
  select count(*), string_agg(coalesce(nullif(btrim(dados ->> 'nome'), ''), nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas where rua_conferir_em is not null and rua_conferir_em < now() - interval '4 hours';
  it := it || jsonb_build_object('codigo', 'conferir_rua', 'nome', 'Rua conferida em até 4 h quando o portal consulta outra rua',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma conferência de rua parada há mais de 4 h' else format('%s conversa(s) com a rua por conferir há mais de 4 h: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Live › Conferir › "Portal: outra rua": refazer na Cobertura escolhendo a rua do cliente e marcar "Conferi".' end);

  -- 15. 0202 — a DFV ao vivo sai pela API do Power BI (o operador da VPS é só reserva)
  select count(*), count(*) filter (where coalesce(detalhe ->> 'fonte', '') <> 'api') into n, n2
    from public.operador_consultas where tipo = 'dfv'
     and criado_em > greatest(now() - interval '24 hours', timestamptz '2026-11-14 20:10-03');   -- API no ar desde 14/11 20h10
  it := it || jsonb_build_object('codigo', 'dfv_pela_api', 'nome', 'DFV consultada pela API do Power BI',
    'nivel', case when n = 0 or n2 * 100 <= n * 5 then 'ok' else 'atencao' end, 'n', n2,
    'texto', case when n = 0 then 'nenhuma consulta DFV nas últimas 24 h' else format('%s de %s consulta(s) DFV nas últimas 24 h fora da API', n2, n) end,
    'fazer', case when n = 0 or n2 * 100 <= n * 5 then null else 'A Nio pode ter republicado o relatório (chave/modelId mudaram): avisar o Claude Code — config_regras.dfv_api.' end);

  -- 16. 0218 — ninguém parado em silêncio: vez da Mari, conversa ativa, sem próximo toque e sem prazo
  select count(*), string_agg(coalesce(nullif(btrim(l.nome), ''), 'sem nome'), ', ' order by l.ultima_em desc) into n, ex
    from public._lead_em_silencio() s join public.v_leads l on l.conversa_id = s.conversa_id;
  it := it || jsonb_build_object('codigo', 'lead_em_silencio', 'nome', 'Ninguém parado em silêncio (vez da Mari sem próximo toque)',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'todo lead com a vez da Mari tem o próximo toque marcado ou um prazo'
                  else format('%s lead(s) com a vez da Mari, sem próximo toque e sem prazo: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Abrir na Live e dar saída, esquentar (🔥) ou assumir. Se a cadência deveria ter marcado o próximo toque, avisar o Claude Code.' end);

  -- 17. 0228 (revisão dos fluxos) — Saída com dono: lead em Saída cuja conversa segue aberta com pessoa ou time no Chatwoot
  -- há mais de 1 h (a Saída devolve para a Mari na hora; "já é cliente Nio" e "não contatar" ficam de fora).
  select count(*), string_agg(coalesce(nullif(btrim(c.dados ->> 'nome'), ''), c.nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas c left join public.vendas v on v.id = c.venda_id
   where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
     and (v.status = 'saida' or (c.venda_id is null and c.saida_em is not null and coalesce(c.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada', 'teste_duplicada')))
     and coalesce(c.funil_destino, '') not in ('ja_cliente_nio', 'ja_cliente') and not coalesce(c.nao_contatar, false)
     and c.chatwoot_status in ('open', 'pending') and (c.chatwoot_agente is not null or c.chatwoot_time is not null)
     and coalesce(c.saida_em, c.funil_destino_em, c.created_at) < now() - interval '1 hour';
  it := it || jsonb_build_object('codigo', 'saida_com_dono', 'nome', 'Lead em Saída sem dono no Chatwoot',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum lead em Saída com a conversa aberta e com dono' else format('%s lead(s) em Saída ainda com pessoa ou time no Chatwoot: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Abrir a ficha: se o cliente ainda quer seguir, Reabrir; senão "Devolver para a Mari". Se voltar a acontecer, avisar o Claude Code.' end);

  -- 18. 0228 — mensagem automática com a conversa assumida por uma pessoa (pela fila do NIOGEN, na voz da Mari, ou a Mari
  -- respondendo o cliente), nas últimas 24 h. "Assumida" = a última ação de pessoa feita pelo NIOGEN foi atribuir.
  select count(*), string_agg(distinct nome, ', ') into n, ex from (
    select c.nome_contato as nome from public.chatwoot_acoes a join public.mari_conversas c on c.id = a.conversa_id
     where a.tipo = 'mensagem' and a.status = 'feita' and a.criada_em > greatest(now() - interval '24 hours', timestamptz '2026-11-15 20:00-03')
       and coalesce(a.payload ->> 'como', '') <> 'humano' and coalesce(c.telefone, '') not like '5500000000%'
       and (select b.tipo from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.status = 'feita' and b.payload ? 'assignee_id'
              and b.tipo in ('atribuir', 'desatribuir') and b.criada_em < a.criada_em order by b.criada_em desc limit 1) = 'atribuir'
    union all
    select c.nome_contato from public.mari_turnos t join public.mari_conversas c on c.id = t.conversa_id
     where t.papel = 'mari' and t.created_at > greatest(now() - interval '24 hours', timestamptz '2026-11-15 20:00-03')   -- correções no ar desde 15/11 ~20h and coalesce(c.telefone, '') not like '5500000000%'
       and (select p.papel from public.mari_turnos p where p.conversa_id = t.conversa_id and p.papel <> 'sistema' and p.created_at < t.created_at
              order by p.created_at desc limit 1) = 'lead'
       and (select b.tipo from public.chatwoot_acoes b where b.conversa_id = t.conversa_id and b.status = 'feita' and b.payload ? 'assignee_id'
              and b.tipo in ('atribuir', 'desatribuir') and b.criada_em < t.created_at order by b.criada_em desc limit 1) = 'atribuir') x;
  it := it || jsonb_build_object('codigo', 'msg_auto_assumida', 'nome', 'Nada automático fala por cima de quem assumiu',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma mensagem automática com a conversa assumida nas últimas 24 h' else format('%s mensagem(ns) automática(s) com a conversa assumida: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code (guard da Mari ou botão sem o "em nome da pessoa"). Ver a conversa e, se precisar, corrigir com o cliente.' end);

  -- 19. 0228 — o banco diz "pessoa/time atribuído" e o Chatwoot diz sem dono (a 0227 espelha; isto acha o que escapar)
  select count(*), string_agg(coalesce(c.nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas c
   where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%' and c.chatwoot_sync_em < now() - interval '10 minutes'
     and ((c.humano_atribuido and c.chatwoot_agente is null) or (c.time_atribuido and c.chatwoot_time is null and c.chatwoot_agente is null))
     and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'atribuir' and a.status in ('pendente', 'executando'));
  it := it || jsonb_build_object('codigo', 'dono_banco_chatwoot', 'nome', 'Dono no NIOGEN = dono no Chatwoot',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todo dono no banco também está no Chatwoot' else format('%s conversa(s) com dono no banco e sem dono no Chatwoot: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: o espelho do Chatwoot (0227) deixou passar. Enquanto isso a cadência dessas conversas fica parada.' end);

  -- 20. 0233 — unidade a confirmar: a unidade do cliente não está na lista da Nio e ninguém resolveu em 4 h
  select count(*), string_agg(coalesce(nullif(btrim(dados ->> 'nome'), ''), nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas where unidade_conferir_em is not null and unidade_conferir_em < now() - interval '4 hours';
  it := it || jsonb_build_object('codigo', 'conferir_unidade', 'nome', 'Unidade confirmada em até 4 h quando não bate com a lista da Nio',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma unidade por confirmar há mais de 4 h' else format('%s conversa(s) com a unidade por confirmar há mais de 4 h: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Live › Conferir › "Unidade a confirmar": confirmar a unidade com o cliente ou pedir o cadastro à Nio e marcar "Conferi".' end);

  -- 21. 0239 — Fila Vero (módulo desligável): a conta da fila fecha
  if to_regclass('public.fila_vero') is not null then
    select count(*) into v_tot from public.fila_vero;
    select coalesce(sum(c), 0) into v_soma from (select count(*) c from public.fila_vero group by status) x;
    select count(*) into n from public.fila_vero
     where (status in ('ja_cliente_nio') and toques > 0)
        or (status = 'opt_out' and ultimo_toque_em > (select max(e.em) from public.fila_vero_eventos e
                                                       where e.fila_id = fila_vero.id and e.para = 'opt_out'));
    select count(*) into n2 from public.fila_vero
     where status = 'enviado' and coalesce(meta_status, 'accepted') = 'accepted' and ultimo_toque_em < now() - interval '24 hours';
    it := it || jsonb_build_object('codigo', 'fila_vero', 'nome', 'Fila Vero: soma por status = total · nenhum toque proibido · status da Meta em 24 h',
      'nivel', case when v_tot <> v_soma or n > 0 then 'falha' when n2 > 0 then 'atencao' else 'ok' end, 'n', (v_tot - v_soma) + n + n2,
      'texto', format('%s na fila (status somam %s) · %s toque(s) em já cliente/opt-out · %s enviado(s) sem status da Meta há mais de 24 h',
                      v_tot, v_soma, n, n2),
      'fazer', case when v_tot <> v_soma or n > 0 then 'Avisar o Claude Code: a fila da Vero tocou quem não podia ou perdeu linha.'
                    when n2 > 0 then 'Conferir o webhook do número do disparo (n8n fila_vero_webhook).' else null end);
    -- 0242: cota do dia e apto parado com o disparo ligado
    select count(*) into n from public.contatos_cliente where toque = 'fila_vero' and direcao = 'saida'
       and (em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date;
    n2 := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'fila_vero_ritmo_dia'), 100);
    it := it || jsonb_build_object('codigo', 'fila_vero_cota', 'nome', 'Fila Vero: envios de hoje dentro do ritmo do dia',
      'nivel', case when n <= n2 then 'ok' else 'falha' end, 'n', greatest(0, n - n2),
      'texto', format('%s envio(s) hoje · ritmo %s/dia', n, n2),
      'fazer', case when n <= n2 then null else 'Pausar a Fila Vero na tela e avisar o Claude Code.' end);
    select count(*) into n from public.fila_vero where status = 'apto' and atualizado_em < now() - interval '7 days'
       and coalesce((select (valor #>> '{}')::boolean from public.config_regras where chave = 'fila_vero_ativo'), false);
    if n > 0 then
      it := it || jsonb_build_object('codigo', 'fila_vero_apto_parado', 'nome', 'Fila Vero: apto parado há mais de 7 dias com o disparo ligado',
        'nivel', 'atencao', 'n', n, 'texto', format('%s apto(s) esperando há mais de 7 dias', n),
        'fazer', 'Ver na tela Fila Vero se o ritmo está baixo ou se a faixa B está fora do disparo.');
    end if;
    select count(*) into n from public.fila_vero where status = 'respondeu' and conversa_id is null;
    if n > 0 then
      it := it || jsonb_build_object('codigo', 'fila_vero_sem_conversa', 'nome', 'Fila Vero: quem respondeu tem conversa na Mari',
        'nivel', 'falha', 'n', n, 'texto', format('%s resposta(s) sem conversa ligada', n),
        'fazer', 'Avisar o Claude Code (gatilho mari_turnos_fila_vero).');
    end if;
  end if;

  return it;
end;
$function$
;
