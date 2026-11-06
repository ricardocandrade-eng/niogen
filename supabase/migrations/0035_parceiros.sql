-- NIOGEN | supabase/migrations/0035_parceiros.sql | 06/11/2026 — Claude Code (prompt nº 22, etapa 1 do Programa Parceiro PAP)
-- Parceiros externos, termo do programa e aceites. Só banco: nenhuma tela, nenhum n8n.
-- Plano: docs/PLANO_PROGRAMA_PARCEIRO_PAP_061126_1250.md (Drive) · prompt: docs/PROMPT_CODE_22_parceiro_pap_banco_061126_1250.md.
-- Numeração: o prompt 22 abriu a faixa 0035–0043; o prompt 23 (API de Conversões) renumera para depois dela.
-- RLS: admin escreve, backoffice lê, vendedor e anon não veem (CPF e Pix do parceiro).

-- ─────────────────────── trigger genérico "só insert" ───────────────────────
create or replace function public.so_insert_trg()
returns trigger language plpgsql set search_path = public as $$
begin
  raise exception 'A tabela % só aceita insert (nada é alterado nem apagado).', tg_table_name using errcode = 'P0001';
end;
$$;
revoke execute on function public.so_insert_trg() from public, anon, authenticated;

-- ─────────────────────── termo do programa e aceites ───────────────────────
create table public.termos_programa (
  versao         text primary key,
  texto          text not null check (btrim(texto) <> ''),
  vigente_desde  timestamptz not null default now(),
  criado_em      timestamptz not null default now(),
  criado_por     uuid references public.usuarios (id) default auth.uid()
);
comment on table public.termos_programa is
  'Termos do Programa Parceiro PAP. Só insert: regra nova = versão nova (e novo aceite no login). F8 do plano.';

create trigger termos_programa_so_insert before update or delete on public.termos_programa
  for each row execute function public.so_insert_trg();

-- ─────────────────────────────── parceiros ───────────────────────────────
create table public.parceiros (
  id                          uuid primary key default gen_random_uuid(),
  nome                        text not null check (btrim(nome) <> ''),
  cpf                         text not null,                -- só dígitos, validado (dígito verificador)
  whatsapp                    text not null,                -- E.164 sem "+": 55 + DDD + número (tel_norm)
  pix_chave                   text,
  pix_titular_conferido_em    timestamptz,                  -- o Ricardo conferiu que a chave é do mesmo CPF (F6)
  pix_titular_conferido_por   uuid references public.usuarios (id),
  status                      text not null default 'aguardando'
                                check (status in ('aguardando', 'ativo', 'suspenso', 'desligado')),
  status_motivo               text,
  status_em                   timestamptz not null default now(),
  status_por                  uuid references public.usuarios (id),
  forma_pagamento             text not null default 'diario' check (forma_pagamento in ('diario', 'quinzenal')),
  forma_pagamento_desde       timestamptz not null default now(),
  incentivo_valor_override    numeric(10, 2) check (incentivo_valor_override is null or incentivo_valor_override >= 0),
  multiplicador_override      numeric(5, 2)  check (multiplicador_override is null or multiplicador_override >= 1),
  aprovado_em                 timestamptz,
  aprovado_por                uuid references public.usuarios (id),
  auth_user_id                uuid unique references auth.users (id) on delete set null,   -- etapa 3 (login da página)
  criado_em                   timestamptz not null default now(),
  constraint parceiros_cpf_unico      unique (cpf),
  constraint parceiros_whatsapp_unico unique (whatsapp),
  constraint parceiros_cpf_fmt        check (cpf ~ '^[0-9]{11}$'),
  constraint parceiros_whatsapp_fmt   check (whatsapp ~ '^55[0-9]{10,11}$')
);
comment on table public.parceiros is 'Programa Parceiro PAP: vendedores externos. Aprovação do Ricardo antes de enviar vendas.';
comment on column public.parceiros.incentivo_valor_override is 'Incentivo quinzenal (R$ por venda) deste parceiro; nulo = padrão de config_parceiros.';
comment on column public.parceiros.multiplicador_override   is 'Multiplicador de pontos do quinzenal deste parceiro; nulo = padrão de config_parceiros.';
comment on column public.parceiros.pix_titular_conferido_em is 'Sem isto nenhum pagamento vira "pago" (F6). Trocar a chave Pix zera.';

-- Normaliza, valida e carimba.
create or replace function public.parceiros_antes()
returns trigger language plpgsql set search_path = public as $$
begin
  new.cpf      := regexp_replace(coalesce(new.cpf, ''), '\D', '', 'g');
  new.whatsapp := public.tel_norm(new.whatsapp);
  new.nome     := btrim(new.nome);
  new.pix_chave := nullif(btrim(coalesce(new.pix_chave, '')), '');

  if not public.mari_cpf_valido(new.cpf) then
    raise exception 'CPF inválido.' using errcode = 'P0001';
  end if;
  if new.whatsapp is null or new.whatsapp !~ '^55[0-9]{10,11}$' then
    raise exception 'WhatsApp inválido: informe DDD + número.' using errcode = 'P0001';
  end if;

  if tg_op = 'UPDATE' then
    -- Trocou a chave Pix: a conferência do titular não vale mais.
    if new.pix_chave is distinct from old.pix_chave then
      new.pix_titular_conferido_em  := null;
      new.pix_titular_conferido_por := null;
    end if;
    if new.forma_pagamento is distinct from old.forma_pagamento then
      new.forma_pagamento_desde := now();
    end if;
    if new.status is distinct from old.status then
      if new.status in ('suspenso', 'desligado') and coalesce(btrim(new.status_motivo), '') = '' then
        raise exception 'Suspender ou desligar parceiro exige motivo.' using errcode = 'P0001';
      end if;
      new.status_em  := now();
      new.status_por := coalesce(auth.uid(), new.status_por);
      if new.status = 'ativo' and old.status = 'aguardando' then
        new.aprovado_em  := coalesce(new.aprovado_em, now());
        new.aprovado_por := coalesce(new.aprovado_por, auth.uid());
      end if;
    end if;
  end if;

  if new.pix_titular_conferido_em is not null and new.pix_chave is null then
    raise exception 'Não há chave Pix para conferir.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke execute on function public.parceiros_antes() from public, anon, authenticated;

create trigger parceiros_antes before insert or update on public.parceiros
  for each row execute function public.parceiros_antes();

create table public.parceiro_aceites (
  id           bigint generated always as identity primary key,
  parceiro_id  uuid not null references public.parceiros (id) on delete restrict,
  versao       text not null references public.termos_programa (versao),
  aceito_em    timestamptz not null default now(),
  unique (parceiro_id, versao)
);
comment on table public.parceiro_aceites is 'Aceite do termo (versão + data). Só insert (F8).';
create trigger parceiro_aceites_so_insert before update or delete on public.parceiro_aceites
  for each row execute function public.so_insert_trg();

-- ─────────────────────────────── RLS ───────────────────────────────
alter table public.termos_programa  enable row level security;
alter table public.parceiros        enable row level security;
alter table public.parceiro_aceites enable row level security;

create policy termos_ler on public.termos_programa
  for select to authenticated using (public.meu_perfil() in ('admin', 'backoffice'));
create policy termos_inserir on public.termos_programa
  for insert to authenticated with check (public.meu_perfil() = 'admin');

create policy parceiros_admin on public.parceiros
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');
create policy parceiros_backoffice_ler on public.parceiros
  for select to authenticated using (public.meu_perfil() = 'backoffice');

create policy aceites_ler on public.parceiro_aceites
  for select to authenticated using (public.meu_perfil() in ('admin', 'backoffice'));

revoke all on public.termos_programa, public.parceiros, public.parceiro_aceites from anon;
