-- NIOGEN | 0177_docs_dispensados_venda_remota.sql | 13/11/2026 — Claude Code (Ricardo, 13/11: "Não tem documento algum pro
-- cliente assinar" · "Sim, desligar")
-- O contrato manda "entregar contratos e termos assinados, com a documentação, em até 15 dias após a habilitação". A cláusula
-- foi escrita para a venda com papel. Na VENDA REMOTA (decisão de 05/11) o cliente não assina nada com a revenda: o aceite é a
-- biometria, no sistema da Nio. O NIOGEN cobrava a entrega em toda venda instalada (ficha, Live, Operações, Dinheiro).
--
-- Decisão do Ricardo: DESLIGAR o aviso. PENDENTE: confirmar com o Rogério, por escrito, que a biometria dispensa a entrega.
--
-- Como: uma chave só — config_regras.docs_exigidos (false). Com ela desligada, a venda que instala já nasce com os documentos
-- "resolvidos" (docs_entregues_em = data da instalação) e com a marca docs_dispensados_em, que as telas mostram como
-- "dispensados (venda remota)". Assim todos os avisos somem de uma vez, sem recriar as views da jornada. Para voltar a cobrar,
-- basta gravar docs_exigidos = true: as próximas instaladas voltam a ter o prazo de 15 dias (as já dispensadas ficam como estão).

alter table public.vendas add column if not exists docs_dispensados_em timestamptz;
comment on column public.vendas.docs_dispensados_em is
  'Quando a entrega de documentos foi DISPENSADA (venda remota: o aceite é a biometria da Nio). Com ela, docs_entregues_em = data da instalação. 0177.';

insert into public.config_regras (chave, valor, descricao) values
  ('docs_exigidos', 'false'::jsonb,
   'Contrato: a venda instalada exige entregar documentos assinados à Nio em 15 dias? false = venda remota, o aceite é a biometria (Ricardo, 13/11/2026; confirmar com o Rogério). true = volta o prazo de 15 dias. 0177.')
on conflict (chave) do nothing;

-- Roda DEPOIS dos outros gatilhos "antes" (o nome com z garante): vendas_antes_status é quem preenche instalado_em.
create or replace function public.vendas_dispensa_docs()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.instalado_em is not null and new.docs_entregues_em is null
     and coalesce((select (valor #>> '{}')::boolean from public.config_regras where chave = 'docs_exigidos'), true) = false then
    new.docs_entregues_em := new.instalado_em;
    new.docs_dispensados_em := now();
  end if;
  return new;
end;
$$;
revoke all on function public.vendas_dispensa_docs() from public, anon, authenticated;
drop trigger if exists vendas_z_dispensa_docs on public.vendas;
create trigger vendas_z_dispensa_docs before insert or update on public.vendas
  for each row execute function public.vendas_dispensa_docs();

-- As que já estavam instaladas e sem documentos: dispensa agora (o próprio gatilho preenche) e deixa o registro na venda.
with alvo as (
  update public.vendas set docs_dispensados_em = docs_dispensados_em
   where instalado_em is not null and docs_entregues_em is null
  returning id
)
insert into public.eventos_venda (venda_id, tipo, detalhe)
select id, 'docs_dispensados', jsonb_build_object('motivo', 'venda remota: o aceite é a biometria no sistema da Nio', 'decisao', 'Ricardo, 13/11/2026',
                                                 'pendente', 'confirmar com o Rogério por escrito') from alvo;
