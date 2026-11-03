-- NIOGEN | supabase/migrations/0006_area_38_cidades.sql | 03/11/2026
-- Área de atuação = as 38 cidades de MG da GDP (Ricardo, 03/11 14h31 · TABELA_VIGENTE §5 e §9), com o cluster de nio_municipios.
-- Planos Empresas BTU (GDP: 700 MB R$ 70 · 800 MB R$ 85 · 1 GB R$ 100, mesmo preço em todos os meios; comissão Especial/BTU
-- da política de 22/10: 263 · 338 · 375). Trava no banco: plano do cluster errado para a cidade, Varejo em cidade BTU
-- (enquanto não houver plano Varejo BTU ligado) e venda fora da área.
-- Idempotente: pode rodar de novo sem duplicar nada.
--
-- Passo 0 (banco real em 03/11): config_area = só JF; nio_municipios = 38 (23 regular, 15 btu), igual à planilha;
-- planos = os 16 da 0005. Achado: os bônus NMEI do cluster btu apontavam para E-REG-* (cluster regular) e nunca casavam;
-- passam a apontar para os E-BTU-* criados aqui.

-- ============================================================================
-- Área: as 38 cidades, ativas, com o cluster da GDP
-- ============================================================================

update public.config_area a set ativo = true, cluster = m.cluster
from public.nio_municipios m
where a.uf = m.uf and a.cidade = m.municipio and a.bairro is null;

insert into public.config_area (cidade, bairro, uf, ativo, cluster)
select m.municipio, null, m.uf, true, m.cluster
from public.nio_municipios m
where not exists (select 1 from public.config_area a where a.uf = m.uf and a.cidade = m.municipio and a.bairro is null);

-- ============================================================================
-- Planos Empresas BTU (mesmos planos do Empresas Regular, outra tabela de preço e comissão)
-- ============================================================================

insert into public.config_planos
  (codigo, portfolio, variante, cluster, segmentos, nome, familia, velocidade, velocidade_mb, wifi, internet_5g, inclusos,
   preco, preco_cartao, comissao, taxa_habilitacao, isencao_meses, taxa_a_vista, forma_pagamento_permitida,
   vigencia_inicio, vigencia_fim, ativo, observacao)
select 'E-BTU-' || r.sufixo, 'empresas', 'regular', 'btu', array['MEI', 'NMEI'],
       r.nome || ' (BTU)', r.familia, r.velocidade, r.velocidade_mb, r.wifi, r.internet_5g, r.inclusos,
       b.preco, null, b.comissao, 540, 24, false, array['boleto', 'dacc', 'cartao'],
       date '2026-10-22', null, true,
       'Tabela Empresas das cidades BTU (GDP 28/10/2026): mesmo preço em todos os meios. Comissão Especial/BTU.'
from (values ('ESS', 70::numeric, 263::numeric), ('SUP', 85, 338), ('ULT', 100, 375)) as b(sufixo, preco, comissao)
join lateral (
  select replace(p.codigo, 'E-REG-', '') as sufixo, p.nome, p.familia, p.velocidade, p.velocidade_mb, p.wifi, p.internet_5g, p.inclusos
  from public.config_planos p where p.codigo = 'E-REG-' || b.sufixo
) r on true
on conflict (codigo) do nothing;

update public.config_bonus set plano_codigo = replace(plano_codigo, 'E-REG-', 'E-BTU-')
where tipo = 'nmei' and cluster = 'btu' and plano_codigo like 'E-REG-%';

-- ============================================================================
-- Trava de área e de tabela
-- ============================================================================

-- Cluster da cidade na área ativa (null = fora da área). Bairro null na área = cidade inteira.
create or replace function public.cluster_da_area(p_cidade text, p_uf text, p_bairro text default null)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select a.cluster
  from public.config_area a
  where a.ativo
    and lower(btrim(a.cidade)) = lower(btrim(p_cidade))
    and upper(btrim(a.uf)) = upper(btrim(coalesce(p_uf, 'MG')))
    and (a.bairro is null or lower(btrim(a.bairro)) = lower(btrim(coalesce(p_bairro, ''))))
  order by a.bairro nulls last
  limit 1
$$;

revoke execute on function public.cluster_da_area(text, text, text) from public, anon;
grant execute on function public.cluster_da_area(text, text, text) to authenticated;

-- Só checa quando muda plano/endereço ou quando a venda entra em 1–5: o OSAB levando 2 → 3 → 4 não passa por aqui de novo.
create or replace function public.vendas_checa_area()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  vendida   boolean := new.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme');
  entrou    boolean;
  mudou     boolean;
  v_cluster text;
  p         public.config_planos%rowtype;
begin
  entrou := vendida and (tg_op = 'INSERT' or old.status not in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme'));
  mudou  := tg_op = 'INSERT'
         or new.plano_id is distinct from old.plano_id
         or new.cidade is distinct from old.cidade
         or new.uf is distinct from old.uf
         or new.bairro is distinct from old.bairro;
  if not (entrou or mudou) then
    return new;
  end if;

  v_cluster := public.cluster_da_area(new.cidade, new.uf, new.bairro);

  if vendida and v_cluster is null then
    raise exception 'Venda bloqueada: % fica fora da área de atuação da Dharma.',
      coalesce(nullif(btrim(new.cidade), '') || coalesce('/' || new.uf, ''), 'o endereço') using errcode = 'P0001';
  end if;

  if new.plano_id is not null and v_cluster is not null then
    select * into p from public.config_planos where id = new.plano_id;
    if p.portfolio = 'varejo' and v_cluster = 'btu'
       and not exists (select 1 from public.config_planos x where x.portfolio = 'varejo' and x.cluster = 'btu' and x.ativo) then
      raise exception 'Tabela Varejo BTU pendente — fale com o Ricardo. (% é cidade BTU: hoje só Empresas vende lá.)', new.cidade
        using errcode = 'P0001';
    end if;
    if p.cluster is distinct from v_cluster then
      raise exception 'Plano "%" é da tabela %, mas % é cidade %. Escolha um plano da tabela %.',
        p.nome, upper(coalesce(p.cluster, '?')), new.cidade, upper(v_cluster), upper(v_cluster) using errcode = 'P0001';
    end if;
  end if;

  return new;
end;
$$;

revoke execute on function public.vendas_checa_area() from public, anon, authenticated;

drop trigger if exists vendas_checa_area on public.vendas;
create trigger vendas_checa_area
  before insert or update on public.vendas
  for each row execute function public.vendas_checa_area();
