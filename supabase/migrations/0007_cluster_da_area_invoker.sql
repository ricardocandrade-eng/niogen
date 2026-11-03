-- NIOGEN | supabase/migrations/0007_cluster_da_area_invoker.sql | 03/11/2026
-- Advisor de segurança: cluster_da_area não precisa de SECURITY DEFINER (config_area é legível por todo usuário ativo,
-- e o trigger vendas_checa_area, que a chama, já roda como dono).

alter function public.cluster_da_area(text, text, text) security invoker;
