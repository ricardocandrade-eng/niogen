-- NIOGEN | supabase/migrations/0133_operador_consultas_decisao.sql | 12/11/2026 — Claude Code
-- Ricardo, 12/11 ~02h30: "a Mari precisa seguir a recomendação do Operador, exatamente como na tela Cobertura" (portal decide,
-- DFV resgata pelos 200 m), "ser flexível para não desperdiçar venda", "o Operador sabe se já existe pedido Nio em aberto — aí a
-- Mari pergunta se procede", "o Operador ainda não grava nada no NIOGEN" e "precisa ter trava de número de consultas à Mari".
-- Decisões dele (12/11): sem cobertura (portal + DFV) → a Mari avisa e registra o interesse; pedido em aberto → automático com
-- o CPF; unidade fora da lista → a Mari pergunta a unidade.
--   operador_consultas          : toda consulta do operador (portal, DFV, duplicidade) — Mari ou tela; só CPF mascarado.
--   _dfv_veredito(jsonb)        : viavel | elegivel | sem | null — igual ao dfvVeredito() da cobertura.html.
--   cobertura_decidir(p, d)     : viavel | elegivel_200m | sem_cobertura | unidade_fora_lista | indefinida — igual à tela.
--   mari_conversas              : + cobertura_decisao, cobertura_detalhe, cobertura_em, viab_consultas,
--                                   nio_pedido_aberto (sim | nao), nio_pedido_aberto_em, dup_consultas.
--   mari_viab_pendentes/_gravar : agora com o DFV e a decisão; TETOS: 3 consultas de endereço por conversa; 3 conversas
--                                   consultadas por telefone em 7 dias (acima disso a Mari segue sem consulta).
--   mari_dup_pendentes/_gravar  : duplicidade de pedido pelo CPF (só com plano escolhido e CPF válido); TETO: 1 por conversa
--                                   e 1 por CPF em 24 h (cache do operador) — nunca para quem não chegou à coleta.

create table if not exists public.operador_consultas (
  id           bigserial primary key,
  parceiro_id  text not null default 'dharma',
  criado_em    timestamptz not null default now(),
  tipo         text not null check (tipo in ('viabilidade', 'dfv', 'duplicidade', 'credito')),
  origem       text not null check (origem in ('mari', 'tela')),
  usuario_id   uuid,
  conversa_id  uuid references public.mari_conversas(id) on delete set null,
  venda_id     uuid,
  cep          text, numero text, complemento text,
  cpf_mascara  text,
  resultado    text,
  decisao      text,
  detalhe      jsonb,
  ms           int
);
create index if not exists operador_consultas_conversa on public.operador_consultas (conversa_id, criado_em desc);
create index if not exists operador_consultas_criado on public.operador_consultas (criado_em desc);
alter table public.operador_consultas enable row level security;
drop policy if exists operador_consultas_ler on public.operador_consultas;
create policy operador_consultas_ler on public.operador_consultas for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke all on public.operador_consultas from anon;
grant select on public.operador_consultas to authenticated;

alter table public.mari_conversas add column if not exists cobertura_decisao text;
alter table public.mari_conversas add column if not exists cobertura_detalhe jsonb;
alter table public.mari_conversas add column if not exists cobertura_em timestamptz;
alter table public.mari_conversas add column if not exists viab_consultas int not null default 0;
alter table public.mari_conversas add column if not exists nio_pedido_aberto text;
alter table public.mari_conversas add column if not exists nio_pedido_aberto_em timestamptz;
alter table public.mari_conversas add column if not exists dup_consultas int not null default 0;
alter table public.mari_conversas drop constraint if exists mari_conversas_cobertura_decisao_check;
alter table public.mari_conversas add constraint mari_conversas_cobertura_decisao_check
  check (cobertura_decisao is null or cobertura_decisao in ('viavel', 'elegivel_200m', 'sem_cobertura', 'unidade_fora_lista', 'indefinida'));
alter table public.mari_conversas drop constraint if exists mari_conversas_nio_pedido_aberto_check;
alter table public.mari_conversas add constraint mari_conversas_nio_pedido_aberto_check
  check (nio_pedido_aberto is null or nio_pedido_aberto in ('sim', 'nao'));

-- DFV: a mesma regra da tela (cobertura.html, dfvVeredito).
create or replace function public._dfv_veredito(d jsonb) returns text language sql immutable as $$
  select case
    when d is null or d ? 'error' then null
    when d->>'fonte' = 'base_congelada' then
      case when (d->'rpc'->>'resultado') in ('viavel', 'viavel_predio') then 'viavel'
           when (d->'rpc'->>'resultado') = 'nao_encontrado' then 'sem'
           when d->'rpc' is null or d->'rpc' = 'null'::jsonb then null
           else 'elegivel' end
    when d->>'match' = 'exato' then 'viavel'
    when coalesce((d->>'total_fachadas_no_cep')::int, 0) > 0 then 'elegivel'
    when d ? 'match' or d ? 'total_fachadas_no_cep' then 'sem'
    else null end
$$;

-- Portal decide, DFV resgata (tela Cobertura). "indefinida" = nenhum dos dois decidiu → a Mari segue e o time confere.
create or replace function public.cobertura_decidir(p_portal text, p_dfv text) returns text language sql immutable as $$
  select case
    when p_portal = 'viavel' then 'viavel'
    when p_portal = 'complemento_fora_lista' then 'unidade_fora_lista'
    when p_portal = 'sem_viabilidade' and p_dfv in ('viavel', 'elegivel') then 'elegivel_200m'
    when p_portal = 'sem_viabilidade' and p_dfv = 'sem' then 'sem_cobertura'
    -- portal fora/não decidiu: o DFV decide, mas "sem" pelo DFV sozinho (retrato de ~15 dias) não recusa venda
    when p_portal is distinct from 'sem_viabilidade' and p_dfv = 'viavel' then 'viavel'
    when p_portal is distinct from 'sem_viabilidade' and p_dfv = 'elegivel' then 'elegivel_200m'
    else 'indefinida' end
$$;

-- Fila da viabilidade (portal + DFV), com os TETOS.
create or replace function public.mari_viab_pendentes(p_limite int default 1)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  -- Teto por telefone: mais de 3 conversas consultadas em 7 dias → não consulta (marca para não voltar à fila).
  update public.mari_conversas c set nio_viab_em = now(), cobertura_decisao = 'indefinida',
         cobertura_detalhe = jsonb_build_object('teto', 'telefone: 3 conversas consultadas em 7 dias'), cobertura_em = now()
   where c.nio_viab_em is null and c.updated_at > now() - interval '12 hours'
     and (select count(*) from public.mari_conversas o
           where o.telefone = c.telefone and o.id <> c.id and o.viab_consultas > 0 and o.cobertura_em > now() - interval '7 days') >= 3;
  with alvo as (
    select c.id from public.mari_conversas c
     where regexp_replace(coalesce(c.cep, ''), '\D', '', 'g') ~ '^\d{8}$'
       and nullif(btrim(coalesce(c.numero, '')), '') is not null
       and c.nio_viab_em is null
       and c.viab_consultas < 3                       -- teto por conversa: 3 endereços
       and coalesce(c.telefone, '') !~ '^55000000'    -- telefones de teste (bateria) nunca vão ao operador
       and coalesce(c.nao_contatar, false) = false
       and coalesce(c.dentro_area, true)
       and c.updated_at > now() - interval '12 hours'
       and (c.venda_id is null or c.handoff_em > now() - interval '12 hours')
     order by c.updated_at desc
     limit greatest(1, least(p_limite, 5))
     for update skip locked
  ), marcadas as (
    update public.mari_conversas c set nio_viab_em = now(), viab_consultas = c.viab_consultas + 1
      from alvo where c.id = alvo.id
    returning c.id, c.cep, c.numero, c.complemento, c.cidade, c.uf
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'conversa_id', id,
           'cep', regexp_replace(cep, '\D', '', 'g'),
           'numero', btrim(numero),
           'complemento', case when complemento ~* '(ap|apto|apartamento|bloco|bl|sala|loja|casa\s+[a-z0-9]\b|fundos|\d)' and complemento !~* '^\s*(casa|nenhum|nao|não|sem)\s*$'
                               then left(btrim(complemento), 60) else '' end,
           'uf', coalesce(uf, 'MG'), 'municipio', upper(coalesce(cidade, '')))), '[]'::jsonb)
    into v from marcadas;
  return v;
end $$;
revoke all on function public.mari_viab_pendentes(int) from public, anon, authenticated;
grant execute on function public.mari_viab_pendentes(int) to service_role;

drop function if exists public.mari_viab_gravar(uuid, jsonb, int, text);
create or replace function public.mari_viab_gravar(p_conversa uuid, p_saida jsonb, p_dfv jsonb default null, p_erro text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_res text; v_op text := p_saida->>'resultado'; v_dfv text; v_dec text; c record;
begin
  if coalesce(p_saida->>'retry', '') = 'true' and p_dfv is null then
    update public.mari_conversas set nio_viab_em = null, viab_consultas = greatest(viab_consultas - 1, 0)
     where id = p_conversa and nio_viab_resultado is null;
    return jsonb_build_object('ok', true, 'resultado', 'de_volta_na_fila');
  end if;
  if coalesce(p_saida->>'retry', '') = 'true' then v_op := null; end if;   -- portal não decidiu; o DFV pode decidir
  v_res := case v_op when 'viavel' then 'viavel' when 'sem_viabilidade' then 'sem_viabilidade'
                     when 'complemento_fora_lista' then 'nao_encontrado' else 'indisponivel' end;
  v_dfv := public._dfv_veredito(p_dfv);
  v_dec := public.cobertura_decidir(v_op, v_dfv);
  update public.mari_conversas set nio_viab_resultado = v_res,
         nio_viab_velocidade = case when v_res = 'viavel' then nullif(p_saida->>'velocidade', '') end,
         nio_viab_em = now(), cobertura_decisao = v_dec, cobertura_em = now(),
         cobertura_detalhe = jsonb_strip_nulls(jsonb_build_object(
           'portal', v_op, 'dfv', v_dfv, 'velocidade', p_saida->>'velocidade',
           'portal_texto', p_saida->'endereco'->>'viabilidade', 'portal_motivo', p_saida->>'motivo',
           'unidades', case when v_op = 'complemento_fora_lista' then p_saida->'opcoes'->'lista' end,
           'dfv_fachadas_cep', p_dfv->'total_fachadas_no_cep', 'dfv_fonte', coalesce(p_dfv->>'fonte', case when p_dfv is not null then 'ao_vivo' end)))
   where id = p_conversa
  returning id, cep, numero, complemento, venda_id into c;
  if c.id is null then return jsonb_build_object('ok', false, 'motivo', 'conversa não encontrada'); end if;
  insert into public.nio_viab_log (origem, conversa_id, cep, numero, complemento, saida, resultado, erro)
  values ('mari', p_conversa, c.cep, c.numero, c.complemento, p_saida - 'cpf_mascara', v_res,
          coalesce(p_erro, case when v_res = 'indisponivel' then left(coalesce(p_saida->>'motivo', v_op, 'portal não decidiu'), 300) end));
  insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cep, numero, complemento, resultado, decisao, detalhe, ms)
  values ('viabilidade', 'mari', p_conversa, c.venda_id, c.cep, c.numero, c.complemento, coalesce(v_op, 'nao_decidiu'), v_dec,
          jsonb_build_object('portal', p_saida - 'cpf_mascara' - 'pedido_portal', 'dfv_veredito', v_dfv), nullif(p_saida->>'ms', '')::int);
  if p_dfv is not null then
    insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cep, numero, complemento, resultado, decisao, detalhe)
    values ('dfv', 'mari', p_conversa, c.venda_id, c.cep, c.numero, c.complemento, v_dfv, v_dec, p_dfv - 'opcoes' - 'unidades');
  end if;
  return jsonb_build_object('ok', true, 'resultado', v_res, 'operador', v_op, 'dfv', v_dfv, 'decisao', v_dec);
end $$;
revoke all on function public.mari_viab_gravar(uuid, jsonb, jsonb, text) from public, anon, authenticated;
grant execute on function public.mari_viab_gravar(uuid, jsonb, jsonb, text) to service_role;

-- Fila da duplicidade de pedido: só quem escolheu plano e mandou CPF válido; 1 por conversa; teto por telefone igual.
create or replace function public._cpf_ok(p text) returns boolean language plpgsql immutable as $$
declare x text := regexp_replace(coalesce(p, ''), '\D', '', 'g'); s int; d int; k int; i int;
begin
  if length(x) <> 11 or x ~ '^(\d)\1{10}$' then return false; end if;
  foreach k in array array[9, 10] loop
    s := 0;
    for i in 1..k loop s := s + substr(x, i, 1)::int * (k + 2 - i); end loop;
    d := (s * 10) % 11; if d = 10 then d := 0; end if;
    if d <> substr(x, k + 1, 1)::int then return false; end if;
  end loop;
  return true;
end $$;

create or replace function public.mari_dup_pendentes(p_limite int default 1)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  with alvo as (
    select c.id from public.mari_conversas c
     where public._cpf_ok(c.dados->>'cpf')
       and c.plano_escolhido is not null
       and c.nio_pedido_aberto_em is null
       and c.dup_consultas < 1
       and coalesce(c.telefone, '') !~ '^55000000'
       and coalesce(c.nao_contatar, false) = false
       and c.updated_at > now() - interval '12 hours'
       and (c.venda_id is null or c.handoff_em > now() - interval '12 hours')
       and (select count(*) from public.mari_conversas o
             where o.telefone = c.telefone and o.id <> c.id and o.dup_consultas > 0 and o.nio_pedido_aberto_em > now() - interval '7 days') < 3
     order by c.updated_at desc
     limit greatest(1, least(p_limite, 3))
     for update skip locked
  ), marcadas as (
    update public.mari_conversas c set nio_pedido_aberto_em = now(), dup_consultas = c.dup_consultas + 1
      from alvo where c.id = alvo.id
    returning c.id, c.dados->>'cpf' cpf
  )
  select coalesce(jsonb_agg(jsonb_build_object('conversa_id', id, 'cpf', regexp_replace(cpf, '\D', '', 'g'))), '[]'::jsonb)
    into v from marcadas;
  return v;
end $$;
revoke all on function public.mari_dup_pendentes(int) from public, anon, authenticated;
grant execute on function public.mari_dup_pendentes(int) to service_role;

create or replace function public.mari_dup_gravar(p_conversa uuid, p_saida jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_op text := p_saida->>'resultado'; v text; c record;
begin
  if coalesce(p_saida->>'retry', '') = 'true' then
    update public.mari_conversas set nio_pedido_aberto_em = null, dup_consultas = greatest(dup_consultas - 1, 0)
     where id = p_conversa and nio_pedido_aberto is null;
    return jsonb_build_object('ok', true, 'resultado', 'de_volta_na_fila');
  end if;
  v := case v_op when 'pedido_em_andamento' then 'sim' when 'sem_pedido_em_andamento' then 'nao' end;
  update public.mari_conversas set nio_pedido_aberto = v, nio_pedido_aberto_em = now()
   where id = p_conversa returning id, venda_id into c;
  if c.id is null then return jsonb_build_object('ok', false, 'motivo', 'conversa não encontrada'); end if;
  insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cpf_mascara, resultado, detalhe, ms)
  values ('duplicidade', 'mari', p_conversa, c.venda_id, p_saida->>'cpf_mascara', coalesce(v_op, 'erro'),
          jsonb_strip_nulls(jsonb_build_object('motivo', p_saida->>'motivo', 'popup', p_saida->'popup'->>'texto',
                                               'etapa_parada', p_saida->'etapa_parada', 'cache', p_saida->'cache')),
          nullif(p_saida->>'ms', '')::int);
  return jsonb_build_object('ok', true, 'resultado', v_op, 'pedido_aberto', v);
end $$;
revoke all on function public.mari_dup_gravar(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.mari_dup_gravar(uuid, jsonb) to service_role;

-- Tela Cobertura (e quem mais consultar pelo NIOGEN): registra a consulta feita por um usuário — só o que a tela já mostrou.
create or replace function public.operador_consulta_registrar(p_tipo text, p_dados jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if public.meu_perfil() is null then raise exception 'operador_consulta_registrar: sem perfil' using errcode = '42501'; end if;
  if p_tipo not in ('viabilidade', 'dfv', 'duplicidade', 'credito') then raise exception 'tipo inválido'; end if;
  insert into public.operador_consultas (tipo, origem, usuario_id, conversa_id, venda_id, cep, numero, complemento, cpf_mascara,
                                         resultado, decisao, detalhe, ms)
  values (p_tipo, 'tela', auth.uid(), nullif(p_dados->>'conversa_id', '')::uuid, nullif(p_dados->>'venda_id', '')::uuid,
          left(p_dados->>'cep', 9), left(p_dados->>'numero', 20), left(p_dados->>'complemento', 60),
          case when p_dados->>'cpf_mascara' ~ '^\d{3}\.\*{3}\.\*{3}-\d{2}$' then p_dados->>'cpf_mascara' end,
          left(p_dados->>'resultado', 60), left(p_dados->>'decisao', 60), p_dados->'detalhe', nullif(p_dados->>'ms', '')::int)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.operador_consulta_registrar(text, jsonb) from public, anon;
grant execute on function public.operador_consulta_registrar(text, jsonb) to authenticated;

-- Endereço mudou → viabilidade e decisão voltam à fila (o teto de 3 por conversa segue valendo).
create or replace function public._mari_viab_endereco_mudou() returns trigger language plpgsql as $$
begin
  if (new.cep is distinct from old.cep or new.numero is distinct from old.numero or new.complemento is distinct from old.complemento)
     and old.nio_viab_em is not null then
    new.nio_viab_em := null; new.nio_viab_resultado := null; new.nio_viab_velocidade := null;
    new.cobertura_decisao := null; new.cobertura_detalhe := null; new.cobertura_em := null;
  end if;
  return new;
end $$;
