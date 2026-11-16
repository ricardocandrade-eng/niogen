-- NIOGEN | supabase/migrations/0239_fila_vero_piloto.sql | 16/11/2026 — Claude Code / Opus 5.5
-- Prompt docs/Prompt_fila_vero_piloto100_161126_1640.md (recorte do v2 docs/Prompt_fila_vero_disparo_v2_131126_1600.md).
-- Fila Vero, piloto de 100: tabela fila_vero + fila_vero_eventos, porta única de status fila_vero_mudar (regra 20),
-- importação (só campos permitidos, sem CPF/RG/mãe/nascimento/e-mail), filtro de Juiz de Fora pela base DFV congelada
-- (nio_hp) — faixa A (endereço) —, registro de envio/falha, webhook do número do disparo (status da Meta e opt-out),
-- clique do botão (docs/fv.html), origem fila_vero na Mari pelo banco (sem tocar no mari_principal) e item na conferência.
-- Módulo desligável (regra 15): nada fora destas funções depende da fila; parceiro_id em tudo.

-- ---------------------------------------------------------------- tabelas
create table if not exists public.fila_vero (
  id              bigint generated always as identity primary key,
  parceiro_id     text not null default 'dharma',
  codigo          text not null unique default substr(md5(random()::text || clock_timestamp()::text), 1, 8),
  nome            text,
  telefone        text not null unique check (telefone ~ '^\d{12,13}$'),
  cep             text,
  rua             text,
  numero          text,
  complemento     text,
  bairro          text,
  cidade          text,
  uf              text,
  segmento        text not null check (segmento in ('instalado', 'nao_instalou', 'churn')),
  ativacao_vero   date,
  status          text not null default 'novo'
                  check (status in ('novo', 'apto', 'enviado', 'respondeu', 'ja_cliente_nio', 'sem_cobertura',
                                    'opt_out', 'encerrado', 'erro')),
  vez             text,
  prazo           timestamptz,
  faixa           text check (faixa in ('endereco', 'bairro')),
  lugar           text,                     -- {{2}} do template, já com a preposição ("na Rua ...")
  toques          int not null default 0,
  ultimo_toque_em timestamptz,
  template        text,
  wamid           text unique,
  meta_status     text,
  entregue_em     timestamptz,
  lido_em         timestamptz,
  clicou_em       timestamptz,
  respondeu_em    timestamptz,
  resposta_disparo_em timestamptz,         -- texto livre que chegou no número do disparo
  auto_resposta_em    timestamptz,
  erro_codigo     text,
  motivo          text,
  conversa_id     uuid,
  venda_id        uuid,
  lote_import     text,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);
create index if not exists fila_vero_status_idx on public.fila_vero (status, cidade);

create table if not exists public.fila_vero_eventos (
  id          bigint generated always as identity primary key,
  parceiro_id text not null default 'dharma',
  fila_id     bigint not null references public.fila_vero (id) on delete cascade,
  de          text,
  para        text,
  motivo      text,
  autor       text,
  em          timestamptz not null default now()
);
create index if not exists fila_vero_eventos_fila_idx on public.fila_vero_eventos (fila_id, em);

alter table public.fila_vero enable row level security;
alter table public.fila_vero_eventos enable row level security;
drop policy if exists fila_vero_ler on public.fila_vero;
create policy fila_vero_ler on public.fila_vero for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
drop policy if exists fila_vero_eventos_ler on public.fila_vero_eventos;
create policy fila_vero_eventos_ler on public.fila_vero_eventos for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke insert, update, delete on public.fila_vero, public.fila_vero_eventos from anon, authenticated;

-- ---------------------------------------------------------------- config
insert into public.config_regras (chave, valor, descricao) values
  ('fila_vero_phone_number_id', '"1124589070738034"', 'Fila Vero: phone_number_id do número do disparo (+55 32 2888-0150, WABA 974428375341104)'),
  ('fila_vero_ativo', 'false', 'Fila Vero: disparo automático ligado (v2). O piloto de 16/11 roda pelo scripts/fila_vero_piloto.py'),
  ('fila_vero_ritmo_dia', '100', 'Fila Vero: envios por dia (rampa do v2 sobe +100 a cada 2 dias)'),
  ('fila_vero_templates', '{}', 'Fila Vero: templates nio_fv_* (id, status, código FV-..) — gravado por scripts/fila_vero_templates.py --status')
on conflict (chave) do nothing;

-- config_links.fila_vero_base (export CSV da planilha da base): gravado pelo CLI em 16/11/2026, fora do repo (público).


-- ---------------------------------------------------------------- porta única de status (regra 20.3)
create or replace function public._fila_vero_guarda()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if coalesce(current_setting('niogen.fila_vero_porta', true), '') <> 'on' then
      raise exception 'fila_vero: status só muda por fila_vero_mudar()' using errcode = '42501';
    end if;
    -- vez e prazo de cada status (regra 20.1/20.2)
    new.vez := case new.status when 'novo' then 'sistema' when 'apto' then 'sistema' when 'enviado' then 'cliente'
                               when 'respondeu' then 'mari' else null end;
    new.prazo := case new.status when 'novo' then now() + interval '24 hours' when 'apto' then now() + interval '7 days'
                                 when 'enviado' then now() + interval '3 days' else null end;
  end if;
  if tg_op = 'INSERT' then
    new.vez := 'sistema';
    new.prazo := now() + interval '24 hours';
  end if;
  new.atualizado_em := now();
  return new;
end $$;

create or replace function public._fila_vero_evento()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.fila_vero_eventos (parceiro_id, fila_id, de, para, motivo, autor)
    values (new.parceiro_id, new.id, null, new.status, 'importado (' || coalesce(new.lote_import, '') || ')', 'importador');
  elsif new.status is distinct from old.status then
    insert into public.fila_vero_eventos (parceiro_id, fila_id, de, para, motivo, autor)
    values (new.parceiro_id, new.id, old.status, new.status,
            nullif(current_setting('niogen.fila_vero_motivo', true), ''),
            coalesce(nullif(current_setting('niogen.fila_vero_autor', true), ''), 'sistema'));
  end if;
  return null;
end $$;

drop trigger if exists fila_vero_guarda on public.fila_vero;
create trigger fila_vero_guarda before insert or update on public.fila_vero
  for each row execute function public._fila_vero_guarda();
drop trigger if exists fila_vero_evento on public.fila_vero;
create trigger fila_vero_evento after insert or update of status on public.fila_vero
  for each row execute function public._fila_vero_evento();

create or replace function public.fila_vero_mudar(p_id bigint, p_para text, p_motivo text, p_autor text)
returns text language plpgsql security definer set search_path = public as $$
declare v_de text;
begin
  if not public._os_pode_gravar() then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select status into v_de from public.fila_vero where id = p_id for update;
  if v_de is null then raise exception 'fila_vero %: não existe', p_id; end if;
  if v_de = p_para then return v_de; end if;
  -- opt-out é final e vence tudo; ja_cliente_nio também não volta
  if v_de in ('opt_out', 'ja_cliente_nio') then
    raise exception 'fila_vero %: % é final', p_id, v_de;
  end if;
  perform set_config('niogen.fila_vero_porta', 'on', true);
  perform set_config('niogen.fila_vero_motivo', coalesce(p_motivo, ''), true);
  perform set_config('niogen.fila_vero_autor', coalesce(p_autor, ''), true);
  update public.fila_vero set status = p_para, motivo = coalesce(p_motivo, motivo) where id = p_id;
  perform set_config('niogen.fila_vero_porta', 'off', true);
  return p_para;
end $$;

-- ---------------------------------------------------------------- importação (CLI, uma vez, por lotes)
create or replace function public.fila_vero_importar(p_linhas jsonb, p_lote text)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public._os_pode_gravar() then raise exception 'Só admin ou backoffice.' using errcode = '42501'; end if;
  insert into public.fila_vero (nome, telefone, cep, rua, numero, complemento, bairro, cidade, uf, segmento, ativacao_vero, lote_import)
  select nullif(btrim(x.nome), ''), x.telefone, nullif(regexp_replace(coalesce(x.cep, ''), '\D', '', 'g'), ''),
         nullif(btrim(x.rua), ''), nullif(btrim(x.numero), ''), nullif(btrim(x.complemento), ''), nullif(btrim(x.bairro), ''),
         nullif(upper(btrim(x.cidade)), ''), nullif(upper(btrim(x.uf)), ''), x.segmento, x.ativacao, p_lote
    from jsonb_to_recordset(p_linhas) as x(nome text, telefone text, cep text, rua text, numero text, complemento text,
                                          bairro text, cidade text, uf text, segmento text, ativacao date)
  on conflict (telefone) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------- {{2}}: "na Rua Fulano de Tal"
create or replace function public._fila_vero_lugar(p_logradouro text)
returns text language sql immutable as $$
  with b as (select initcap(lower(btrim(regexp_replace(coalesce(p_logradouro, ''), '\s+', ' ', 'g')))) s),
  c as (select regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
               ' ' || s || ' ', ' De ', ' de ', 'g'), ' Da ', ' da ', 'g'), ' Do ', ' do ', 'g'),
               ' Dos ', ' dos ', 'g'), ' Das ', ' das ', 'g'), ' E ', ' e ', 'g') s from b),
  d as (select btrim(regexp_replace(s, '^ Av\.? ', ' Avenida ')) s from c)
  select case when s = '' then null
              when s ~* '^(beco|largo|parque|condominio|condomínio|conjunto|caminho|jardim)\M' then 'no ' || s
              else 'na ' || s end from d;
$$;

-- ---------------------------------------------------------------- filtro do piloto: Juiz de Fora, faixa A (endereço)
create or replace function public.fila_vero_filtrar_jf()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; n_apto int := 0; n_cli int := 0; n_sem int := 0; n_resto int := 0;
begin
  if not public._os_pode_gravar() then raise exception 'Só admin ou backoffice.' using errcode = '42501'; end if;
  for r in
    with f as (
      select fv.id, fv.cep, regexp_replace(coalesce(fv.numero, ''), '\D', '', 'g') as num, fv.complemento, fv.telefone
        from public.fila_vero fv
       where fv.status = 'novo' and fv.cidade like 'JUIZ DE FORA%'),
    hp as (
      select h.cep, h.numero_dig, bool_or(h.viabilidade = 'Viável') as viavel, sum(h.hp_tot) as hp_tot,
             sum(h.hc_tot) as hc_tot, sum(h.hp_livre) as hp_livre, min(h.logradouro) as logradouro
        from public.nio_hp h where h.municipio = 'JUIZ DE FORA' group by h.cep, h.numero_dig)
    select f.id, f.telefone, hp.viavel, hp.hp_tot, hp.hc_tot, hp.hp_livre, hp.logradouro,
           exists (select 1 from public.vendas v
                    where v.status <> 'saida'
                      and (public.tel_e164(v.cliente_whatsapp) = '+' || f.telefone
                           or (regexp_replace(coalesce(v.cep, ''), '\D', '', 'g') = f.cep
                               and regexp_replace(coalesce(v.numero, ''), '\D', '', 'g') = f.num
                               and (public.dfv_comp_norm(v.complemento) is null or public.dfv_comp_norm(f.complemento) is null
                                    or public.dfv_comp_norm(v.complemento) = public.dfv_comp_norm(f.complemento))))) as venda_nossa,
           exists (select 1 from public.mari_conversas c where c.telefone = f.telefone) as conversa,
           exists (select 1 from public.mari_conversas c where c.telefone = f.telefone and c.nao_contatar) as nao_contatar
      from f left join hp on hp.cep = f.cep and hp.numero_dig = f.num and f.num <> ''
  loop
    if r.nao_contatar then
      perform public.fila_vero_mudar(r.id, 'opt_out', 'não contatar (Mari)', 'filtro');
    elsif r.venda_nossa then
      perform public.fila_vero_mudar(r.id, 'ja_cliente_nio', 'venda Nio no mesmo telefone ou endereço', 'filtro'); n_cli := n_cli + 1;
    elsif r.hp_tot is not null and r.hc_tot > 0 and (r.hp_tot = 1 or r.hp_livre = 0) then
      perform public.fila_vero_mudar(r.id, 'ja_cliente_nio', format('DFV: endereço com cliente Nio (hc %s de %s HP)', r.hc_tot, r.hp_tot), 'filtro');
      n_cli := n_cli + 1;
    elsif r.hp_tot is not null and not r.viavel then
      perform public.fila_vero_mudar(r.id, 'sem_cobertura', 'DFV: endereço sem viabilidade', 'filtro'); n_sem := n_sem + 1;
    elsif r.hp_tot is not null and r.viavel and r.hp_livre > 0 and r.hc_tot = 0 and not r.conversa then
      update public.fila_vero set faixa = 'endereco', lugar = public._fila_vero_lugar(r.logradouro) where id = r.id;
      perform public.fila_vero_mudar(r.id, 'apto', 'DFV: CEP + número com cobertura e sem cliente Nio', 'filtro'); n_apto := n_apto + 1;
    else
      update public.fila_vero set motivo = case when r.conversa then 'já conversa com a Mari'
                                                when r.hp_tot is null then 'sem CEP + número na DFV (faixa B no v2)'
                                                else 'prédio com cliente Nio: conferir unidade (v2)' end
       where id = r.id;
      n_resto := n_resto + 1;
    end if;
  end loop;
  return jsonb_build_object('apto', n_apto, 'ja_cliente_nio', n_cli, 'sem_cobertura', n_sem, 'segue_novo', n_resto);
end $$;

-- ---------------------------------------------------------------- disparo (scripts/fila_vero_piloto.py)
create or replace function public.fila_vero_lote(p_n int)
returns table (id bigint, codigo text, telefone text, primeiro_nome text, lugar text, segmento text)
language sql security definer set search_path = public as $$
  select fv.id, fv.codigo, fv.telefone, initcap(lower(split_part(btrim(fv.nome), ' ', 1))), fv.lugar, fv.segmento
    from public.fila_vero fv
   where public._os_pode_gravar()
     and fv.status = 'apto' and fv.faixa = 'endereco' and fv.cidade like 'JUIZ DE FORA%'
     and fv.toques = 0 and fv.lugar is not null
     and fv.telefone ~ '^55\d{2}9\d{8}$'
     and length(split_part(btrim(coalesce(fv.nome, '')), ' ', 1)) >= 2
   order by md5(fv.codigo)
   limit greatest(0, least(p_n, 100));
$$;

create or replace function public.fila_vero_registrar_envio(p_id bigint, p_template text, p_wamid text)
returns void language plpgsql security definer set search_path = public as $$
declare v public.fila_vero%rowtype;
begin
  if not public._os_pode_gravar() then raise exception 'Só admin ou backoffice.' using errcode = '42501'; end if;
  update public.fila_vero set toques = toques + 1, ultimo_toque_em = now(), template = p_template, wamid = p_wamid,
         meta_status = 'accepted' where id = p_id returning * into v;
  insert into public.contatos_cliente (canal, direcao, por, em, resumo, telefone, toque, tipo)
  values ('whatsapp', 'saida', 'mari', now(), 'Fila Vero: template ' || p_template, v.telefone, 'fila_vero', 'ativo');
  perform public.fila_vero_mudar(p_id, 'enviado', 'template ' || p_template, 'piloto');
end $$;

create or replace function public.fila_vero_registrar_falha(p_id bigint, p_template text, p_codigo text, p_msg text)
returns text language plpgsql security definer set search_path = public as $$
declare v_para text;
begin
  if not public._os_pode_gravar() then raise exception 'Só admin ou backoffice.' using errcode = '42501'; end if;
  update public.fila_vero set erro_codigo = p_codigo, template = p_template where id = p_id;
  v_para := case when p_codigo in ('131050') then 'opt_out' else 'erro' end;
  perform public.fila_vero_mudar(p_id, v_para, left(format('Meta %s: %s', p_codigo, p_msg), 300), 'piloto');
  return v_para;
end $$;

-- ---------------------------------------------------------------- webhook do número do disparo (n8n fila_vero_webhook)
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
    select * into v from public.fila_vero where telefone = m ->> 'from';
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

-- respostas em texto no número do disparo que ainda não receberam o link da Mari (o script responde e marca)
create or replace function public.fila_vero_auto_respostas()
returns table (id bigint, telefone text, codigo text, template text)
language sql security definer set search_path = public as $$
  select fv.id, fv.telefone, fv.codigo, fv.template from public.fila_vero fv
   where public._os_pode_gravar() and fv.resposta_disparo_em is not null and fv.auto_resposta_em is null
     and fv.status not in ('opt_out', 'ja_cliente_nio') and fv.resposta_disparo_em > now() - interval '24 hours';
$$;
create or replace function public.fila_vero_auto_respondida(p_id bigint)
returns void language sql security definer set search_path = public as $$
  update public.fila_vero set auto_resposta_em = now() where id = p_id and public._os_pode_gravar();
$$;

-- ---------------------------------------------------------------- clique no botão (docs/fv.html, sem login)
create or replace function public.fila_vero_clique(p_codigo text, p_template text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v public.fila_vero%rowtype;
begin
  if p_codigo !~ '^[a-z0-9]{6,12}$' then return; end if;
  update public.fila_vero set clicou_em = now() where codigo = p_codigo and clicou_em is null returning * into v;
  if v.id is not null then
    insert into public.fila_vero_eventos (parceiro_id, fila_id, de, para, motivo, autor)
    values (v.parceiro_id, v.id, v.status, v.status, 'clicou no botão (' || coalesce(nullif(p_template, ''), '?') || ')', 'fv.html');
  end if;
end $$;
revoke all on function public.fila_vero_clique(text, text) from public;
grant execute on function public.fila_vero_clique(text, text) to anon, authenticated;

-- ---------------------------------------------------------------- origem fila_vero na Mari, pelo banco
create or replace function public._fila_vero_origem()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_cod text; v public.fila_vero%rowtype; v_tel text;
begin
  begin   -- nunca derruba a gravação do turno da Mari
    v_cod := lower(substring(new.texto from '\(FV-[A-Za-z0-9]+-([a-z0-9]{6,12})\)'));
    if v_cod is not null then
      select * into v from public.fila_vero where codigo = v_cod;
    end if;
    if v.id is null and new.texto ~ '\(FV-' then
      select telefone into v_tel from public.mari_conversas where id = new.conversa_id;
      select * into v from public.fila_vero where telefone = v_tel;
    end if;
    if v.id is null then return null; end if;
    update public.mari_conversas set origem = 'fila_vero'
     where id = new.conversa_id and coalesce(origem, 'direto') = 'direto';
    update public.fila_vero set conversa_id = coalesce(conversa_id, new.conversa_id),
                                respondeu_em = coalesce(respondeu_em, now()),
                                clicou_em = coalesce(clicou_em, now())
     where id = v.id;
    if v.status in ('apto', 'enviado', 'erro', 'encerrado') then
      perform set_config('niogen.fila_vero_porta', 'on', true);
      perform set_config('niogen.fila_vero_motivo', 'falou com a Mari (código ' || coalesce(v_cod, 'FV') || ')', true);
      perform set_config('niogen.fila_vero_autor', 'mari_turnos', true);
      update public.fila_vero set status = 'respondeu' where id = v.id;
      perform set_config('niogen.fila_vero_porta', 'off', true);
    end if;
  exception when others then
    raise warning 'fila_vero_origem: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists mari_turnos_fila_vero on public.mari_turnos;
create trigger mari_turnos_fila_vero after insert on public.mari_turnos
  for each row when (new.papel = 'lead' and new.texto like '%(FV-%')
  execute function public._fila_vero_origem();

-- ---------------------------------------------------------------- resumo para o Ricardo
create or replace function public.fila_vero_resumo()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'por_status', (select jsonb_object_agg(status, n) from (select status, count(*) n from public.fila_vero group by 1) x),
    'enviados_hoje', (select count(*) from public.fila_vero where ultimo_toque_em::date = (now() at time zone 'America/Sao_Paulo')::date),
    'entregues', (select count(*) from public.fila_vero where entregue_em is not null),
    'lidos', (select count(*) from public.fila_vero where lido_em is not null),
    'cliques', (select count(*) from public.fila_vero where clicou_em is not null),
    'na_mari', (select count(*) from public.fila_vero where conversa_id is not null),
    'por_template', (select jsonb_object_agg(template, j) from (
        select template, jsonb_build_object('enviados', count(*), 'entregues', count(entregue_em), 'cliques', count(clicou_em),
                                            'na_mari', count(conversa_id), 'opt_out', count(*) filter (where status = 'opt_out')) j
          from public.fila_vero where template is not null group by template) t),
    'falhas', (select jsonb_object_agg(coalesce(erro_codigo, '?'), n) from (
        select erro_codigo, count(*) n from public.fila_vero where status = 'erro' or erro_codigo is not null group by 1) f))
  where public._os_pode_gravar();
$$;

revoke all on function public.fila_vero_mudar(bigint, text, text, text), public.fila_vero_importar(jsonb, text),
  public.fila_vero_filtrar_jf(), public.fila_vero_lote(int), public.fila_vero_registrar_envio(bigint, text, text),
  public.fila_vero_registrar_falha(bigint, text, text, text), public.fila_vero_webhook(jsonb),
  public.fila_vero_auto_respostas(), public.fila_vero_auto_respondida(bigint), public.fila_vero_resumo() from public, anon;
grant execute on function public.fila_vero_mudar(bigint, text, text, text), public.fila_vero_resumo() to authenticated;

-- ---------------------------------------------------------------- conferência de todo dia (regra 20.5)
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
    select count(*) into n from public.fila_vero where status = 'respondeu' and conversa_id is null;
    if n > 0 then
      it := it || jsonb_build_object('codigo', 'fila_vero_sem_conversa', 'nome', 'Fila Vero: quem respondeu tem conversa na Mari',
        'nivel', 'falha', 'n', n, 'texto', format('%s resposta(s) sem conversa ligada', n),
        'fazer', 'Avisar o Claude Code (gatilho mari_turnos_fila_vero).');
    end if;
  end if;

  return it;
end;
$function$;
