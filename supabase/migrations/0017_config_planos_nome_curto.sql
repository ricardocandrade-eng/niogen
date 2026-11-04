-- NIOGEN | supabase/migrations/0017_config_planos_nome_curto.sql | 04/11/2026
-- Vendas v2 (prompt nº 10, docs/PADRAO_TELAS_NIOGEN_041126_1225.md): a lista mostra o nome curto do plano
-- ("Super 1 GB", "Empresas Essencial 700 MB") com a forma de pagamento embaixo.
--  * config_planos.nome_curto (nova, opcional): só apresentação. O front cai em `nome` quando estiver vazio.
--  * Nada muda em comissão, preço, trigger, RPC ou view (v_funil continua igual; o front lê o nome curto de config_planos).
-- A variante (BTU, sem fidelidade) não entra no nome curto: a cidade diz o cluster e a forma/fidelidade vão na linha de baixo.

alter table public.config_planos add column if not exists nome_curto text;

update public.config_planos set nome_curto = case
    when portfolio = 'varejo'   and familia = 'Fibra'     then 'Fibra 600 MB'
    when portfolio = 'varejo'   and familia = 'Essencial' then 'Essencial 800 MB'
    when portfolio = 'varejo'   and familia = 'Super'     then 'Super 1 GB'
    when portfolio = 'varejo'   and familia = 'Ultra'     then 'Ultra 1 GB + Mesh'
    when portfolio = 'empresas' and familia = 'Fibra'     then 'Empresas Fibra 400 MB'
    when portfolio = 'empresas' and familia = 'Essencial' then 'Empresas Essencial 700 MB'
    when portfolio = 'empresas' and familia = 'Super'     then 'Empresas Super 800 MB'
    when portfolio = 'empresas' and familia = 'Ultra'     then 'Empresas Ultra 1 GB'
  end
where nome_curto is null;

comment on column public.config_planos.nome_curto is 'Nome curto para listas (Vendas v2). Só apresentação; vazio = usa nome.';
