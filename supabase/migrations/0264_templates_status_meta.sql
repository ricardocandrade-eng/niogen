-- NIOGEN | supabase/migrations/0264_templates_status_meta.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Conserto (Ricardo, 17/11: "Sim" — 4c + dois consertos). Caso: o template nio_cartao_cadastro foi APROVADO na Meta e ficou
-- PENDING na nossa tabela desde 14/11 — a cadência só usa template APPROVED, então o aviso do cartão não saía e ninguém via.
-- Agora o fluxo waba_qualidade (n8n, 8h e 14h) também lê a lista de templates da WABA Nio e entrega aqui: o status da nossa
-- tabela passa a ser o da Meta. Casa pelo meta_id (ou, sem ele, pelo nome). Status que a nossa tabela não tem viram o mais
-- próximo (em recurso = PENDING; apagado, arquivado, limite = DISABLED). Devolve o que mudou e o que sumiu da Meta.
-- DISABLED na nossa tabela é decisão nossa e fica (a Meta aprovar não religa um template aposentado).
-- Grava em waba_templates_leituras (uma linha por leitura com mudança ou sumiço) para o Painel poder mostrar.
begin;

create table if not exists public.waba_templates_leituras (
  id       bigserial primary key,
  lido_em  timestamptz not null default now(),
  mudaram  jsonb not null default '[]'::jsonb,
  sumiram  jsonb not null default '[]'::jsonb
);
alter table public.waba_templates_leituras enable row level security;
drop policy if exists waba_templates_leituras_ler on public.waba_templates_leituras;
create policy waba_templates_leituras_ler on public.waba_templates_leituras for select to authenticated
  using ((select public.meu_perfil()) = any (array['admin', 'backoffice']));
grant select on public.waba_templates_leituras to authenticated;

create or replace function public.waba_templates_status_sync(p_lista jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m jsonb; t public.config_templates_waba; st text;
  mudaram jsonb := '[]'::jsonb; sumiram jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(p_lista) <> 'array' or jsonb_array_length(p_lista) = 0 then
    return jsonb_build_object('ok', false, 'erro', 'lista vazia — a Meta não respondeu; nada mudou');
  end if;
  for m in select * from jsonb_array_elements(p_lista) loop
    st := case upper(coalesce(m ->> 'status', ''))
            when 'APPROVED' then 'APPROVED' when 'PENDING' then 'PENDING' when 'IN_APPEAL' then 'PENDING'
            when 'REJECTED' then 'REJECTED' when 'PAUSED' then 'PAUSED' when '' then null
            else 'DISABLED' end;
    continue when st is null;
    select * into t from public.config_templates_waba x
     where (x.meta_id is not null and x.meta_id = m ->> 'id') or (x.meta_id is null and x.nome = m ->> 'name')
     limit 1;
    -- DISABLED na nossa tabela é decisão NOSSA (ex.: nio_lembrete_biometria, trocado pelo _v2): a Meta não o religa.
    if found and t.status <> 'DISABLED' and t.status is distinct from st then
      update public.config_templates_waba set status = st, meta_id = coalesce(meta_id, m ->> 'id'), atualizado_em = now() where nome = t.nome;
      mudaram := mudaram || jsonb_build_object('nome', t.nome, 'de', t.status, 'para', st, 'meta', m ->> 'status');
    end if;
  end loop;
  select coalesce(jsonb_agg(jsonb_build_object('nome', x.nome, 'status', x.status)), '[]'::jsonb) into sumiram
    from public.config_templates_waba x
   where x.meta_id is not null and x.status <> 'DISABLED'
     and not exists (select 1 from jsonb_array_elements(p_lista) e where e ->> 'id' = x.meta_id);
  if jsonb_array_length(mudaram) > 0 or jsonb_array_length(sumiram) > 0 then
    insert into public.waba_templates_leituras (mudaram, sumiram) values (mudaram, sumiram);
  end if;
  return jsonb_build_object('ok', true, 'lidos', jsonb_array_length(p_lista), 'mudaram', mudaram, 'sumiram', sumiram);
end $$;
revoke execute on function public.waba_templates_status_sync(jsonb) from public, anon, authenticated;
grant execute on function public.waba_templates_status_sync(jsonb) to service_role;

commit;
