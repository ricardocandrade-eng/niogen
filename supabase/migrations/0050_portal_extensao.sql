-- NIOGEN | supabase/migrations/0050_portal_extensao.sql | 06/11/2026 — Claude Code (prompt 28)
-- Resumo: o que a extensão do Chrome "NIOGEN no Portal" lê e grava. Tudo SECURITY INVOKER: vale o RLS de quem está logado
-- (admin e backoffice veem tudo; vendedor só as vendas dele). Nada de service role na extensão.
--   1. usuarios.matricula_pap: matrícula do vendedor no portal PAP (etapa 1 do Novo Pedido; TT837725, TT837726…).
--   2. portal_prontas(): a fila "Prontas para o portal" = Qualificado (0) sem nº de pedido — o mesmo estágio em que a ficha
--      mostra os cartões "Viabilidade" e "Dados para o portal PAP" (prompt 27). Devolve só o resumo e o que falta.
--   3. dados_portal(venda): o bloco "Dados para o portal PAP" em JSON, na ordem das etapas do Novo Pedido.
--   4. portal_gravar_pedido(venda, pedido): grava o nº do pedido digitado pelo humano e registra o evento pedido_aberto_portal
--      (o evento guarda só o fato — nunca o número nem dado do cliente).
-- Numeração: 0045 continua reservada ao prompt 23 (API de Conversões).

-- ---------------------------------------------------------------- 1. matrícula do vendedor no portal
alter table public.usuarios add column if not exists matricula_pap text;
alter table public.usuarios drop constraint if exists usuarios_matricula_pap_check;
alter table public.usuarios add constraint usuarios_matricula_pap_check
  check (matricula_pap is null or matricula_pap ~ '^[A-Za-z]{2}[0-9]{4,8}$');
comment on column public.usuarios.matricula_pap is
  'Matrícula do vendedor no portal PAP da Nio (campo "matrícula do vendedor" da etapa 1 do Novo Pedido). Ex.: TT837725.';

-- ---------------------------------------------------------------- 2. fila "Prontas para o portal"
create or replace function public.portal_prontas()
returns table (
  venda_id      uuid,
  cliente_nome  text,
  bairro        text,
  cidade        text,
  plano_nome    text,
  faltas        text[],
  criado_em     timestamptz
)
language sql
stable
security invoker
set search_path = public
as $$
  select v.id,
         v.cliente_nome,
         v.bairro,
         v.cidade,
         p.nome,
         array_remove(array[
           case when coalesce(btrim(v.cep), '') = '' then 'o CEP' end,
           case when coalesce(btrim(v.numero), '') = '' then 'o número' end,
           case when coalesce(btrim(v.ponto_referencia), '') = '' then 'a referência' end,
           case when coalesce(btrim(v.cliente_cpf_cnpj), '') = '' then 'o CPF/CNPJ' end,
           case when coalesce(btrim(v.cliente_whatsapp), '') = '' then 'o telefone' end,
           case when coalesce(btrim(v.cliente_email), '') = '' then 'o e-mail' end,
           case when v.plano_id is null then 'o plano' end,
           case when v.forma_pagamento is null then 'a forma de pagamento' end,
           case when coalesce(btrim(v.instalacao_preferencia), '') = '' then 'o período preferido' end,
           case when coalesce(btrim(u.matricula_pap), '') = '' then 'a matrícula do vendedor' end
         ], null),
         v.criado_em
    from public.vendas v
    left join public.config_planos p on p.id = v.plano_id
    left join public.usuarios u on u.id = v.vendedor_id
   where public.meu_perfil() is not null
     and v.status = '0_qualificado'
     and coalesce(btrim(v.nio_pedido), '') = ''
   order by v.criado_em
$$;

revoke all on function public.portal_prontas() from public, anon;
grant execute on function public.portal_prontas() to authenticated;

-- ---------------------------------------------------------------- 3. bloco "Dados para o portal PAP" em JSON
create or replace function public.dados_portal(p_venda_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v      public.vendas%rowtype;
  plano  text;
  mat    text;
  vnome  text;
  adics  jsonb;
  doc    text;
begin
  if public.meu_perfil() is null then
    return null;
  end if;

  select * into v from public.vendas where id = p_venda_id;   -- passa pelo RLS de quem chamou
  if not found then
    return null;
  end if;

  select p.nome into plano from public.config_planos p where p.id = v.plano_id;
  select u.matricula_pap, u.nome into mat, vnome from public.usuarios u where u.id = v.vendedor_id;
  select coalesce(jsonb_agg(jsonb_build_object('nome', a.nome, 'qtd', va.qtd) order by a.nome), '[]'::jsonb)
    into adics
    from public.venda_adicionais va
    join public.config_adicionais a on a.id = va.adicional_id
   where va.venda_id = v.id;

  doc := regexp_replace(coalesce(v.cliente_cpf_cnpj, ''), '\D', '', 'g');

  return jsonb_build_object(
    'venda_id', v.id,
    'status', v.status,
    'pedido', nullif(btrim(coalesce(v.nio_pedido, '')), ''),
    'pdv', jsonb_build_object(
      'uf', 'MG',
      'codigo', '1069521',
      'nome', 'DHARMA TELECOM LTDA',
      'matricula', nullif(btrim(coalesce(mat, '')), ''),
      'vendedor', vnome),
    'viabilidade', jsonb_build_object(
      'cep', nullif(btrim(coalesce(v.cep, '')), ''),
      'numero', nullif(btrim(coalesce(v.numero, '')), ''),
      'complemento', nullif(btrim(coalesce(v.complemento, '')), ''),
      'referencia', nullif(btrim(coalesce(v.ponto_referencia, '')), ''),
      'logradouro', v.logradouro,
      'bairro', v.bairro,
      'cidade', v.cidade,
      'uf', v.uf),
    'cliente', jsonb_build_object(
      'tipo', case when length(doc) = 14 then 'CNPJ' else 'CPF' end,
      'documento', nullif(doc, ''),
      'nome', v.cliente_nome,
      'segmento', v.segmento),
    'contato', jsonb_build_object(
      'celular', nullif(regexp_replace(coalesce(v.cliente_whatsapp, ''), '\D', '', 'g'), ''),
      'email', nullif(btrim(coalesce(v.cliente_email, '')), '')),
    'oferta', jsonb_build_object(
      'plano', plano,
      'adicionais', adics,
      'forma_pagamento', v.forma_pagamento),
    'agendamento', jsonb_build_object(
      'preferencia', nullif(btrim(coalesce(v.instalacao_preferencia, '')), ''))
  );
end;
$$;

revoke all on function public.dados_portal(uuid) from public, anon;
grant execute on function public.dados_portal(uuid) to authenticated;

-- ---------------------------------------------------------------- 4. nº do pedido digitado pelo humano
create or replace function public.portal_gravar_pedido(p_venda_id uuid, p_pedido text)
returns boolean
language plpgsql
security invoker
set search_path = public
as $$
declare
  ped text := btrim(coalesce(p_pedido, ''));
  st  text;
begin
  if public.meu_perfil() is null then
    raise exception 'Sem acesso.' using errcode = '42501';
  end if;
  if ped !~ '^[A-Za-z0-9._/-]{4,40}$' then
    raise exception 'Número do pedido inválido: use só letras, números, ponto, barra ou hífen (4 a 40 caracteres).' using errcode = '22023';
  end if;

  select status into st from public.vendas where id = p_venda_id;   -- RLS: só enxerga a venda quem pode
  if not found then
    raise exception 'Venda não encontrada ou sem acesso.' using errcode = 'P0002';
  end if;
  if st = 'saida' then
    raise exception 'A venda está em Saída; reabra pela ficha antes de registrar o pedido.' using errcode = '22023';
  end if;

  update public.vendas set nio_pedido = ped where id = p_venda_id;
  insert into public.eventos_venda (venda_id, tipo, detalhe)
  values (p_venda_id, 'pedido_aberto_portal', jsonb_build_object('origem', 'extensao'));
  return true;
end;
$$;

revoke all on function public.portal_gravar_pedido(uuid, text) from public, anon;
grant execute on function public.portal_gravar_pedido(uuid, text) to authenticated;
