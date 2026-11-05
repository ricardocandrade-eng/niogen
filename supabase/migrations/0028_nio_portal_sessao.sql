-- NIOGEN | supabase/migrations/0028_nio_portal_sessao.sql | 05/11/2026 — Claude Code (prompt nº 16)
-- 1) nio_portal_sessao: estado da sessão do portal PAP (login BO por navegador, Playwright). Uma linha só (id = 1).
--    Decisão do Ricardo (05/11): o login roda numa VPS no Brasil e as consultas rodam DENTRO da página do portal
--    (Plano B), então o token fica no navegador do serviço e normalmente NÃO é gravado aqui (coluna `token` existe
--    para o Plano A e fica nula). Mesmo assim a tabela é só do service_role: RLS ligada, sem policy, sem grant.
--    O NIOGEN enxerga só o estado (sem token) pela função nio_portal_sessao_status() — admin/backoffice.
-- 2) mari_cadencia_parar ganha p_nao_contatar (etiqueta `nao-contatar` no Chatwoot = não tocar, adendo 2): marca
--    mari_conversas.nao_contatar e a escada para de vez (sem isso a conversa voltava a cada 10 min só para parar).

create table if not exists public.nio_portal_sessao (
  id              smallint primary key default 1 check (id = 1),
  token           text,                         -- só Plano A; no Plano B fica nulo (o token vive no navegador do serviço)
  obtido_em       timestamptz,                  -- último login bem-sucedido
  expira_estimado timestamptz,                  -- obtido_em + 20 h (a sessão do portal durou > 22 h em 04→05/11)
  ultimo_uso      timestamptz,                  -- última chamada à API do portal
  ultimo_erro     text,                         -- "código: mensagem" sem segredo (ex.: "4: senha recusada")
  ultimo_erro_em  timestamptz,
  origem_login    text,                         -- playwright
  meta            jsonb not null default '{}'::jsonb,   -- usuario_formato, kmsi, plano (A|B), host do serviço — nada secreto
  atualizado_em   timestamptz not null default now()
);

comment on table public.nio_portal_sessao is
  'Sessão do portal PAP (login BO por Playwright, prompt 16). Só service_role. Token nunca em config_links.';

alter table public.nio_portal_sessao enable row level security;
revoke all on public.nio_portal_sessao from public, anon, authenticated;
grant all on public.nio_portal_sessao to service_role;

create or replace function public.nio_portal_sessao_carimbo()
returns trigger language plpgsql set search_path = public as $$
begin
  new.atualizado_em := now();
  return new;
end;
$$;
drop trigger if exists nio_portal_sessao_carimbo on public.nio_portal_sessao;
create trigger nio_portal_sessao_carimbo before insert or update on public.nio_portal_sessao
  for each row execute function public.nio_portal_sessao_carimbo();
revoke execute on function public.nio_portal_sessao_carimbo() from public, anon, authenticated;

-- Estado para a tela (sem token). "ok" = login válido e sem erro depois dele.
create or replace function public.nio_portal_sessao_status()
returns jsonb language sql stable security definer set search_path = public as $$
  select case
    when public.meu_perfil() not in ('admin', 'backoffice') then null
    else coalesce((
      select jsonb_build_object(
        'obtido_em', s.obtido_em,
        'expira_estimado', s.expira_estimado,
        'ultimo_uso', s.ultimo_uso,
        'ultimo_erro', s.ultimo_erro,
        'ultimo_erro_em', s.ultimo_erro_em,
        'ok', s.obtido_em is not null and coalesce(s.expira_estimado, now()) > now()
              and (s.ultimo_erro_em is null or s.ultimo_erro_em < s.obtido_em),
        'sem_sessao_desde', case
          when s.ultimo_erro_em is not null and (s.obtido_em is null or s.ultimo_erro_em >= s.obtido_em)
            then coalesce(least(s.expira_estimado, s.ultimo_erro_em), s.ultimo_erro_em)
          when s.expira_estimado is not null and s.expira_estimado <= now() then s.expira_estimado end)
      from public.nio_portal_sessao s where s.id = 1), jsonb_build_object('ok', false, 'nunca', true))
  end
$$;
revoke execute on function public.nio_portal_sessao_status() from public, anon;
grant execute on function public.nio_portal_sessao_status() to authenticated, service_role;

-- mari_cadencia_parar com nao-contatar (assinatura nova; a antiga sai para não haver duas)
drop function if exists public.mari_cadencia_parar(uuid, boolean, boolean, boolean);
create or replace function public.mari_cadencia_parar(p_conversa uuid, p_humano boolean default false,
  p_time boolean default false, p_resolvida boolean default false, p_nao_contatar boolean default false)
returns jsonb language sql set search_path = public as $$
  update public.mari_conversas set
    humano_atribuido = humano_atribuido or coalesce(p_humano, false),
    time_atribuido = time_atribuido or coalesce(p_time, false),
    chatwoot_resolvida = chatwoot_resolvida or coalesce(p_resolvida, false),
    nao_contatar = nao_contatar or coalesce(p_nao_contatar, false)
  where id = p_conversa
  returning jsonb_build_object('ok', true, 'humano', humano_atribuido, 'time', time_atribuido,
                               'resolvida', chatwoot_resolvida, 'nao_contatar', nao_contatar)
$$;
revoke execute on function public.mari_cadencia_parar(uuid, boolean, boolean, boolean, boolean) from public, anon, authenticated;
grant execute on function public.mari_cadencia_parar(uuid, boolean, boolean, boolean, boolean) to service_role;
