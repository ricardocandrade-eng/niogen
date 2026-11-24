-- NIOGEN | supabase/migrations/0374_nfse_emissao.sql | 23/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 23/11: "Sim, fazer o botão" (Emitir NF na Conciliação) — escolhas: "Um clique" (emite, gera o PDF e manda o e-mail à
-- Nio depois de UMA confirmação) e "Teste primeiro" (começa na produção restrita: nota sem valor fiscal, e-mail só para o remetente).
-- Peças: serviço niogen-nfse na VPS do n8n (nfse/servico.py — certificado A1 e senha do Zoho só no .env de lá), edge function
-- nfse-emitir (só admin), botão no pé de cada pedido da Conciliação.
--
-- O quê:
--   1. config_regras.nfse — {ambiente: 'restrita'|'producao', serie, proximo: {restrita, producao}}. Trocar para produção é
--      um update nesta chave, decidido pelo Ricardo (não há botão para isso).
--   2. nfse_emissoes — uma linha por tentativa: pedido/item, ambiente, série, nº da DPS, situação, chave, nº da NFS-e, e-mail.
--   3. nfse_emissao_pedir(documento, item) — a porta (admin): confere o pedido, não deixa duas emissões ao mesmo tempo nem
--      NF de produção para pedido que já tem NF, e RESERVA o nº da DPS (série + número nunca se repetem — E0014).
--   4. nfse_emissao_resultado(id, dados) — só a chave de serviço (a edge function): grava o que a Sefin e o Zoho devolveram;
--      em PRODUÇÃO, nota emitida vira a NF do pedido em nio_ciclo_nf (e o e-mail, o envio à Nio). Restrita não toca nio_ciclo_nf.
--   5. bucket privado nfse (PDF e XML), leitura só admin.
--   6. conferencia_itens(): item 35 "Emissão de NFS-e" (pedida há > 10 min sem resposta = falha; e-mail que falhou = atenção).
-- Regra 20: (1) sem estado de lead · (2) emissão sem resposta vira falha na conferência; e-mail falho tem "Reenviar" ·
-- (3) só por função, com autor · (4) a NF vem da Sefin (XML) e o envio, do Zoho; o NIOGEN registra · (5) item 35.
begin;

insert into public.config_regras (chave, valor, descricao)
values ('nfse', '{"ambiente": "restrita", "serie": 1, "proximo": {"restrita": 2, "producao": 1}}'::jsonb,
        'Emissão da NFS-e pelo botão da Conciliação (0374). ambiente restrita = teste (sem valor fiscal, e-mail só para o remetente); producao = NF de verdade, e-mail à Nio. proximo = 1º nº da DPS de cada ambiente (a série 1 nº 1 da restrita foi usada no teste manual de 23/11).')
on conflict (chave) do nothing;

create table if not exists public.nfse_emissoes (
  id                uuid primary key default gen_random_uuid(),
  parceiro_id       text not null default 'dharma',
  ciclo             text not null,
  documento_compras text not null,
  item              text not null default '10',
  valor             numeric(12, 2) not null,
  ambiente          text not null check (ambiente in ('restrita', 'producao')),
  serie             int  not null,
  numero            bigint not null,
  situacao          text not null default 'pedida'
                    check (situacao in ('pedida', 'emitida', 'enviada', 'erro_emissao', 'erro_email')),
  chave             text,
  n_nfse            text,
  emitida_em        timestamptz,
  email_para        text,
  email_enviado_em  timestamptz,
  pdf_path          text,
  xml_path          text,
  erro              text,
  pedida_por        uuid default auth.uid(),
  pedida_em         timestamptz not null default now(),
  atualizada_em     timestamptz not null default now(),
  unique (parceiro_id, ambiente, serie, numero)
);
create index if not exists nfse_emissoes_pedido_idx on public.nfse_emissoes (documento_compras, item, pedida_em desc);
alter table public.nfse_emissoes enable row level security;
drop policy if exists nfse_emissoes_ler on public.nfse_emissoes;
create policy nfse_emissoes_ler on public.nfse_emissoes for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke all on public.nfse_emissoes from anon, authenticated;
grant select on public.nfse_emissoes to authenticated;
grant all on public.nfse_emissoes to service_role;
comment on table public.nfse_emissoes is
  'Emissões de NFS-e pelo botão da Conciliação (0374). Grava só nfse_emissao_pedir (admin) e nfse_emissao_resultado (serviço).';

create or replace function public.nfse_emissao_pedir(p_documento text, p_item text default '10')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cfg  jsonb := coalesce((select valor from public.config_regras where chave = 'nfse'), '{}'::jsonb);
  amb  text := coalesce(cfg ->> 'ambiente', 'restrita');
  ser  int  := coalesce((cfg ->> 'serie')::int, 1);
  it   text := coalesce(nullif(btrim(p_item), ''), '10');
  ped  record;
  num  bigint;
  novo uuid;
begin
  if coalesce(public.meu_perfil(), '') <> 'admin' and auth.role() is distinct from 'service_role' then
    raise exception 'Só admin emite NF.' using errcode = '42501';
  end if;
  if amb not in ('restrita', 'producao') then raise exception 'config_regras.nfse.ambiente inválido: %', amb; end if;
  select p.ciclo, p.ciclo_nio, p.valor into ped from public.nio_extrato_pedidos p
   where p.documento_compras = btrim(p_documento) and coalesce(p.item, '10') = it limit 1;
  if ped is null then raise exception 'Pedido % item % não está em nenhum extrato importado.', p_documento, it; end if;
  if coalesce(ped.valor, 0) <= 0 then raise exception 'Pedido sem valor.'; end if;
  if exists (select 1 from public.nfse_emissoes e where e.documento_compras = btrim(p_documento) and e.item = it
               and e.situacao = 'pedida' and e.pedida_em > now() - interval '10 minutes') then
    raise exception 'Já há uma emissão deste pedido em andamento. Aguarde a resposta.';
  end if;
  if amb = 'producao' and (exists (select 1 from public.nio_ciclo_nf f where f.documento_compras = btrim(p_documento)
                                     and f.item = it and f.nf_numero is not null)
                        or exists (select 1 from public.nfse_emissoes e where e.ambiente = 'producao'
                                     and e.documento_compras = btrim(p_documento) and e.item = it
                                     and e.situacao in ('emitida', 'enviada', 'erro_email'))) then
    raise exception 'Este pedido já tem NF. Para mandar o e-mail de novo, use "Reenviar e-mail".';
  end if;
  perform pg_advisory_xact_lock(hashtext('nfse_numero_' || amb));
  -- tentativa anterior deste pedido que NÃO terminou em nota (sem resposta ou recusada pela Sefin): reusa o MESMO nº da DPS.
  -- Assim, se a nota saiu e a resposta se perdeu, o serviço acha a DPS já processada (HEAD /dps) e não emite outra.
  select e.id, e.numero into novo, num from public.nfse_emissoes e
   where e.documento_compras = btrim(p_documento) and e.item = it and e.ambiente = amb and e.serie = ser
     and e.situacao in ('pedida', 'erro_emissao')
   order by e.pedida_em desc limit 1;
  if novo is not null then
    update public.nfse_emissoes set situacao = 'pedida', erro = null, pedida_em = now(), pedida_por = auth.uid(), atualizada_em = now()
     where id = novo;
  else
    select greatest(coalesce(max(e.numero) + 1, 1), coalesce((cfg #>> array['proximo', amb])::bigint, 1)) into num
      from public.nfse_emissoes e where e.ambiente = amb and e.serie = ser and e.parceiro_id = 'dharma';
    insert into public.nfse_emissoes (ciclo, documento_compras, item, valor, ambiente, serie, numero)
    values (ped.ciclo, btrim(p_documento), it, ped.valor, amb, ser, num)
    returning id into novo;
  end if;
  return jsonb_build_object('id', novo, 'ambiente', amb, 'serie', ser, 'numero', num, 'ciclo', ped.ciclo, 'ciclo_nio', ped.ciclo_nio,
                            'documento_compras', btrim(p_documento), 'item', it, 'valor', ped.valor,
                            'competencia', (now() at time zone 'America/Sao_Paulo')::date);
end;
$$;
revoke all on function public.nfse_emissao_pedir(text, text) from public, anon;
grant execute on function public.nfse_emissao_pedir(text, text) to authenticated, service_role;

-- dados: {situacao, chave?, n_nfse?, emitida_em?, email_para?, email_enviado_em?, pdf_path?, xml_path?, erro?}
create or replace function public.nfse_emissao_resultado(p_id uuid, p_dados jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  e   public.nfse_emissoes;
  sit text := p_dados ->> 'situacao';
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Só o serviço grava o resultado da emissão.' using errcode = '42501';
  end if;
  if sit not in ('emitida', 'enviada', 'erro_emissao', 'erro_email') then raise exception 'Situação inválida: %', sit; end if;
  update public.nfse_emissoes set
    situacao = sit,
    chave = coalesce(p_dados ->> 'chave', chave),
    n_nfse = coalesce(p_dados ->> 'n_nfse', n_nfse),
    emitida_em = coalesce((p_dados ->> 'emitida_em')::timestamptz, emitida_em),
    email_para = coalesce(p_dados ->> 'email_para', email_para),
    email_enviado_em = coalesce((p_dados ->> 'email_enviado_em')::timestamptz, email_enviado_em),
    pdf_path = coalesce(p_dados ->> 'pdf_path', pdf_path),
    xml_path = coalesce(p_dados ->> 'xml_path', xml_path),
    erro = case when sit in ('erro_emissao', 'erro_email') then left(p_dados ->> 'erro', 2000) else null end,
    atualizada_em = now()
  where id = p_id
  returning * into e;
  if e.id is null then raise exception 'Emissão % não encontrada.', p_id; end if;
  -- só a NF de PRODUÇÃO vira a NF do pedido (a de teste não tem valor fiscal)
  if e.ambiente = 'producao' and e.n_nfse is not null and sit in ('emitida', 'enviada', 'erro_email') then
    insert into public.nio_ciclo_nf (ciclo, documento_compras, item, nf_numero, nf_emitida_em, nf_enviada_em, nf_registrada_por, nf_registrada_em, obs)
    values (e.ciclo, e.documento_compras, e.item, e.n_nfse, (coalesce(e.emitida_em, now()) at time zone 'America/Sao_Paulo')::date,
            case when e.email_enviado_em is not null then (e.email_enviado_em at time zone 'America/Sao_Paulo')::date end,
            e.pedida_por, now(), 'Emitida pelo NIOGEN (chave ' || coalesce(e.chave, '?') || ')')
    on conflict (parceiro_id, documento_compras, item) do update
       set nf_numero = excluded.nf_numero, nf_emitida_em = excluded.nf_emitida_em,
           nf_enviada_em = coalesce(excluded.nf_enviada_em, public.nio_ciclo_nf.nf_enviada_em),
           nf_registrada_por = excluded.nf_registrada_por, nf_registrada_em = excluded.nf_registrada_em, obs = excluded.obs
     where public.nio_ciclo_nf.pago_em is null;
  end if;
end;
$$;
revoke all on function public.nfse_emissao_resultado(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.nfse_emissao_resultado(uuid, jsonb) to service_role;

-- a última emissão de cada pedido, para a tela
create or replace view public.v_nfse_emissoes with (security_invoker = true) as
select distinct on (documento_compras, item, ambiente) *
  from public.nfse_emissoes
 order by documento_compras, item, ambiente, pedida_em desc;
revoke all on public.v_nfse_emissoes from anon;
grant select on public.v_nfse_emissoes to authenticated, service_role;

-- PDF e XML das notas: bucket privado; leitura só admin/backoffice (link assinado pela edge function)
-- (condicional: a cópia local do portão não tem o esquema storage; a edge function lê e grava com a chave de serviço)
do $b$ begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('nfse', 'nfse', false, 5242880, array['application/pdf', 'application/xml', 'text/xml'])
    on conflict (id) do nothing;
  end if;
end $b$;

-- conferência: item 35
do $m$
declare
  d text := pg_get_functiondef('public.conferencia_itens(text)'::regprocedure);
  fim text := E'\n  return it;\nend';
  item text := $x$
  -- 35. 0374 — emissão de NFS-e pelo botão: nada parado sem resposta; e-mail que falhou tem de ser reenviado
  select count(*)::int into n from public.nfse_emissoes where situacao = 'pedida' and pedida_em < now() - interval '10 minutes';
  select count(*)::int into n2 from public.v_nfse_emissoes where situacao = 'erro_email' and ambiente = 'producao';
  it := it || jsonb_build_object('codigo', 'nfse_emissao', 'nome', 'Emissão de NFS-e',
    'nivel', case when n > 0 then 'falha' when n2 > 0 then 'atencao' else 'ok' end, 'n', n + n2,
    'texto', case when n + n2 = 0 then 'nenhuma emissão parada nem e-mail de NF por reenviar'
                  else concat_ws(' · ', case when n > 0 then format('%s emissão(ões) sem resposta há mais de 10 min', n) end,
                                        case when n2 > 0 then format('%s NF emitida(s) cujo e-mail à Nio falhou', n2) end) end,
    'fazer', case when n > 0 then 'Conferir no portal nacional (www.nfse.gov.br) se a nota saiu e avisar o Claude Code: o serviço niogen-nfse pode estar fora.'
                  when n2 > 0 then 'Conciliação › pé do ciclo › Reenviar e-mail.' end);
$x$;
begin
  if position('nfse_emissao' in d) > 0 then
    raise notice '0374: o item nfse_emissao já existe — nada a fazer';
    return;
  end if;
  if (length(d) - length(replace(d, fim, ''))) / length(fim) <> 1 then
    raise exception '0374: não achei um único "return it;" no fim de conferencia_itens — refazer a migration a partir da versão no ar';
  end if;
  execute replace(d, fim, item || fim);
end $m$;

commit;
