-- NIOGEN | supabase/migrations/0195_venda_bruta_cartao_pago.sql | 14/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 14/11: "Venda Bruta é na OS gerada, e em casos de venda com cartão, com OS gerada e pagamento realizado."
-- vendido_em (a data que o Painel, o Funil, a tela Vendas, o pulso e o resumo contam) passa a ser a data da VENDA BRUTA:
--   * boleto / DACC: a OS gravada (como na 0194);
--   * cartão: a OS gravada E o cadastro do cartão feito — vendido_em fica vazio até lá e ganha a data do cadastro.
-- O status da venda não muda (Ativação/Agenda desde a OS): muda só a contagem.
-- "Cartão cadastrado" (vendas.cartao_pago_em) vem da Nio (regra 20.4): a leitura da OS (operador, OSAB ou extensão) que sai de
-- "Aguardando Pagamento" depois da biometria validada — a mesma regra da cadência e do Live (0194). Instalada = cartão pago.
-- Regra 20: não cria status; o carimbo muda só por gatilho do banco (leitura da OS ou instalação), com evento 'cartao_cadastrado'.

begin;

alter table public.vendas add column if not exists cartao_pago_em timestamptz;
comment on column public.vendas.cartao_pago_em is
  '0195: cadastro do cartão feito (Consulta OS saiu de "Aguardando Pagamento" depois da biometria, ou instalada). Cartão: a venda bruta (vendido_em) é esta data.';

-- Carimbo da venda bruta: roda depois de vendas_antes_status (que põe vendido_em na mudança de status).
create or replace function public.vendas_venda_bruta()
 returns trigger
 language plpgsql
 set search_path to 'public'
as $function$
begin
  if new.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme') then
    if coalesce(new.forma_pagamento, '') = 'cartao' then
      if new.cartao_pago_em is null and (new.instalado_em is not null or new.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')) then
        new.cartao_pago_em := coalesce(new.instalado_em, now());
      end if;
      new.vendido_em := case when new.cartao_pago_em is null then null else coalesce(new.vendido_em, new.cartao_pago_em) end;
    else
      new.vendido_em := coalesce(new.vendido_em, new.nio_os_em, now());
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists vendas_y_venda_bruta on public.vendas;
create trigger vendas_y_venda_bruta before insert or update on public.vendas
  for each row execute function public.vendas_venda_bruta();

-- A leitura da OS que sai de "Aguardando Pagamento" depois da biometria validada = cartão cadastrado.
create or replace function public._os_cartao_pago()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  vid uuid;
begin
  if new.venda_id is null or new.estado is null or new.estado = 'aguardando_pagamento' then return new; end if;
  update public.vendas v set cartao_pago_em = now()
   where v.id = new.venda_id and v.forma_pagamento = 'cartao' and v.cartao_pago_em is null
     and v.biometria_status = 'validada' and new.mudou_em > v.biometria_validada_em
  returning v.id into vid;
  if vid is not null then
    insert into public.eventos_venda (venda_id, tipo, detalhe)
    values (vid, 'cartao_cadastrado', jsonb_build_object('origem', new.origem_ultima, 'status_ordem', new.status_ordem, 'pedido', new.pedido));
  end if;
  return new;
end;
$function$;

drop trigger if exists os_andamento_cartao_pago on public.os_andamento;
create trigger os_andamento_cartao_pago after insert or update on public.os_andamento
  for each row execute function public._os_cartao_pago();

-- Vendas no cartão que já existem: as instaladas (e as já lidas fora de "Aguardando Pagamento" depois da biometria) ficam pagas;
-- as que ainda esperam o cadastro perdem o vendido_em até o cartão ser cadastrado.
update public.vendas v set cartao_pago_em = coalesce(v.instalado_em,
         (select a.mudou_em from public.os_andamento a where a.venda_id = v.id and a.estado is not null
             and a.estado <> 'aguardando_pagamento' and a.mudou_em > v.biometria_validada_em limit 1))
 where v.forma_pagamento = 'cartao' and v.cartao_pago_em is null;
update public.vendas set forma_pagamento = forma_pagamento   -- recalcula vendido_em pelo gatilho novo
 where forma_pagamento = 'cartao' and status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme');

notify pgrst, 'reload schema';

commit;
