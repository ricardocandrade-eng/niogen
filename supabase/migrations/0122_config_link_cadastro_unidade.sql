-- NIOGEN | supabase/migrations/0122_config_link_cadastro_unidade.sql | 11/11/2026 — Claude Code
-- Consulta de crédito: quando a unidade do cliente (apartamento/complemento) não está na lista do portal PAP, o backoffice
-- pede o cadastro à Nio por um Google Forms (Ricardo, 11/11 ~19h20). O link fica em config_links (só usuário logado lê),
-- como o do DFV — a URL é gravada fora do repo (o repo é público). Regra 15: nada fixo no código.
insert into public.config_links (chave, nome, url, observacao)
values ('nio_cadastro_unidade', 'Nio — cadastro de apartamento/complemento (Forms)', null,
        'Usado na tela Consulta de crédito, resultado "Unidade fora da lista do portal". URL gravada fora do repo.')
on conflict (chave) do nothing;
