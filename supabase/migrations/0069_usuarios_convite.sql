-- NIOGEN | supabase/migrations/0069_usuarios_convite.sql | 08/11/2026 — Claude Code (Onda 1.3: acesso real ao NIOGEN)
-- Até aqui só o Ricardo tinha login (linha em usuarios criada à mão em 03/11). Para vendedor e backoffice entrarem:
--  1) Convite pelo painel do Supabase (Authentication › Users › Invite user) → a pessoa recebe o e-mail, abre o link no
--     NIOGEN (Site URL = Pages) e cria a própria senha na tela de login (index.html, 08/11). Ninguém digita senha por ela.
--  2) Este gatilho cria a linha em usuarios na hora do convite, INATIVA, com perfil 'vendedor' (ou o perfil/nome que vier
--     no user_metadata). Sem ativar, o exigirLogin barra ("sem perfil ativo") — o admin escolhe o perfil e ativa na
--     aba Configurações › Equipe.
--  3) admin_equipe(): a lista da equipe com e-mail e último login (o e-mail mora em auth.users, que o front não lê).
--     Só admin. A edição (perfil, nome, ativo) é UPDATE direto em usuarios, já liberado só para admin pelo RLS de 0001.

create or replace function public._usuario_novo()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_perfil text := lower(coalesce(new.raw_user_meta_data ->> 'perfil', ''));
begin
  if v_perfil not in ('admin', 'vendedor', 'backoffice') or v_perfil = 'admin' then
    v_perfil := 'vendedor';   -- admin nunca nasce de convite
  end if;
  insert into public.usuarios (id, nome, perfil, ativo)
  values (new.id,
          coalesce(nullif(btrim(new.raw_user_meta_data ->> 'nome'), ''), split_part(coalesce(new.email, 'novo'), '@', 1)),
          v_perfil, false)
  on conflict (id) do nothing;
  return new;
end;
$$;
revoke execute on function public._usuario_novo() from public, anon, authenticated;

drop trigger if exists usuario_novo on auth.users;
create trigger usuario_novo after insert on auth.users
  for each row execute function public._usuario_novo();

create or replace function public.admin_equipe()
returns table (id uuid, nome text, perfil text, cidade text, ativo boolean, email text,
               convidado_em timestamptz, confirmado_em timestamptz, ultimo_login timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if public.meu_perfil() is distinct from 'admin' then
    raise exception 'só admin';
  end if;
  return query
    select u.id, u.nome, u.perfil, u.cidade, u.ativo, a.email::text, a.invited_at, a.email_confirmed_at, a.last_sign_in_at
      from public.usuarios u join auth.users a on a.id = u.id
     order by u.ativo desc, u.nome;
end;
$$;
revoke execute on function public.admin_equipe() from public, anon;
grant execute on function public.admin_equipe() to authenticated;
