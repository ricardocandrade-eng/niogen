-- NIOGEN | supabase/migrations/0037_config_parceiros.sql | 06/11/2026 — Claude Code (prompt nº 22, etapa 1)
-- Configuração única do Programa Parceiro PAP. Valores iniciais ZERADOS/NULOS: degraus, incentivo e bônus
-- ficam em branco até o Ricardo preencher no Admin (etapa 2). SLA 2 h, 3 tentativas, dia 5 e 20/5 vêm do plano.

create or replace function public.config_parceiros_degraus_ok(j jsonb)
returns boolean language sql immutable set search_path = public as $$
  select jsonb_typeof(j) = 'array'
     and not exists (
       select 1 from jsonb_array_elements(j) e
        where not case
          when jsonb_typeof(e) = 'object'
           and (e ->> 'pontos') ~ '^[0-9]+(\.[0-9]+)?$'
           and (e ->> 'premio') ~ '^[0-9]+(\.[0-9]+)?$'
          then (e ->> 'pontos')::numeric > 0
          else false end)
$$;

create table public.config_parceiros (
  id                                boolean primary key default true check (id),     -- linha única
  degraus                           jsonb not null default '[]'::jsonb
                                      check (public.config_parceiros_degraus_ok(degraus)),   -- [{pontos, premio}]
  incentivo_quinzenal_valor         numeric(10, 2) check (incentivo_quinzenal_valor is null or incentivo_quinzenal_valor >= 0),
  incentivo_quinzenal_multiplicador numeric(5, 2)  check (incentivo_quinzenal_multiplicador is null or incentivo_quinzenal_multiplicador >= 1),
  bonus_boas_vindas_valor           numeric(10, 2) check (bonus_boas_vindas_valor is null or bonus_boas_vindas_valor >= 0),
  bonus_boas_vindas_prazo_dias      int check (bonus_boas_vindas_prazo_dias is null or bonus_boas_vindas_prazo_dias > 0),
  sla_conferencia_horas             int not null default 2 check (sla_conferencia_horas > 0),
  conferencia_max_tentativas        int not null default 3 check (conferencia_max_tentativas > 0),
  dia_apuracao                      int not null default 5 check (dia_apuracao between 1 and 28),
  quinzenal_dias                    int[] not null default array[20, 5]
                                      check (cardinality(quinzenal_dias) = 2
                                             and quinzenal_dias[1] between 16 and 28 and quinzenal_dias[2] between 1 and 15),
  termo_versao_vigente              text references public.termos_programa (versao),
  atualizado_em                     timestamptz not null default now(),
  atualizado_por                    uuid references public.usuarios (id) default auth.uid()
);
comment on column public.config_parceiros.degraus is 'Degraus de pontos do mês: [{"pontos":1000,"premio":500}, …]. Vale só o MAIOR degrau atingido.';
comment on column public.config_parceiros.quinzenal_dias is
  '{dia da 1ª quinzena, dia da 2ª}: instalações de 1–15 pagas no 1º; de 16–fim, no 2º do mês seguinte. Padrão {20,5}.';
comment on column public.config_parceiros.sla_conferencia_horas is 'Prazo da conferência, em horas dentro do horário de contato do contrato.';

insert into public.config_parceiros (id) values (true) on conflict do nothing;

create or replace function public.config_parceiros_carimba()
returns trigger language plpgsql set search_path = public as $$
begin
  new.atualizado_em  := now();
  new.atualizado_por := coalesce(auth.uid(), new.atualizado_por);
  return new;
end;
$$;
revoke execute on function public.config_parceiros_carimba() from public, anon, authenticated;
create trigger config_parceiros_carimba before update on public.config_parceiros
  for each row execute function public.config_parceiros_carimba();

alter table public.config_parceiros enable row level security;
create policy config_parceiros_admin on public.config_parceiros
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');
create policy config_parceiros_ler on public.config_parceiros
  for select to authenticated using (public.meu_perfil() = 'backoffice');
revoke all on public.config_parceiros from anon;
