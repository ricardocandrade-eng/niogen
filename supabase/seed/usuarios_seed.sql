-- NIOGEN | supabase/seed/usuarios_seed.sql | 03/11/2026
-- Liga o primeiro usuário do Supabase Auth (o Ricardo) ao perfil admin.
-- Antes: criar o usuário em Authentication › Users › Add user (e-mail + senha, "Auto Confirm").
-- O e-mail não fica aqui de propósito: o seed pega o usuário mais antigo do Auth.

insert into public.usuarios (id, nome, perfil, cidade)
select id, 'Ricardo', 'admin', 'Juiz de Fora'
from auth.users
order by created_at
limit 1
on conflict (id) do nothing;
