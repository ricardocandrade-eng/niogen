-- NIOGEN | supabase/migrations/0123_config_link_pedido_liberacao.sql | 12/11/2026 — Claude Code
-- Consulta de cobertura: portal sem viabilidade mas DFV com fachada viável no CEP ("Elegível pelos 200 m") → o backoffice
-- pede a liberação à Nio por um Google Forms (Ricardo, 12/11). Link em config_links (só usuário logado lê), como o da 0122 —
-- a URL é gravada fora do repo (o repo é público). Regra 15: nada fixo no código.
insert into public.config_links (chave, nome, url, observacao)
values ('nio_pedido_liberacao', 'Nio — pedido de liberação (regra dos 200 m) (Forms)', null,
        'Usado na tela Consulta de cobertura, resultado "Elegível pelos 200 m". URL gravada fora do repo.')
on conflict (chave) do nothing;
