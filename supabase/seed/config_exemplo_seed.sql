-- NIOGEN | supabase/seed/config_exemplo_seed.sql | 03/11/2026
-- SEED DE EXEMPLO — NÃO É A TABELA REAL.
-- Serve só para testar o formulário de venda enquanto a tabela de planos da Nio não chega.
-- Preço fica null de propósito (não inventamos preço). Comissão = Anexo II, Regular, biometria aprovada.
-- Quando a tabela real chegar:
--   delete from public.config_planos where nome like 'EXEMPLO %';
--   delete from public.config_area   where cidade = 'Juiz de Fora' and bairro is null;  -- se a área real for outra

insert into public.config_planos (nome, familia, velocidade, segmento, preco, comissao, forma_pagamento_permitida)
values
  ('EXEMPLO Essencial 600MB', 'Regular', '600MB', 'PF',   null, 350, array['boleto', 'cartao', 'dacc']),
  ('EXEMPLO Super 800MB',     'Regular', '800MB', 'PF',   null, 450, array['boleto', 'cartao', 'dacc']),
  ('EXEMPLO Ultra 1GB',       'Regular', '1GB',   'PF',   null, 550, array['boleto', 'cartao', 'dacc']),
  ('EXEMPLO Super 800MB',     'Regular', '800MB', 'MEI',  null, 450, array['boleto', 'cartao', 'dacc']),
  ('EXEMPLO Super 800MB',     'Regular', '800MB', 'NMEI', null, 450, array['boleto', 'cartao', 'dacc']);

-- Área de atuação provisória: Juiz de Fora inteira, até a lista real do APP NiO PAP / Rogério.
insert into public.config_area (cidade, bairro, uf) values ('Juiz de Fora', null, 'MG');
