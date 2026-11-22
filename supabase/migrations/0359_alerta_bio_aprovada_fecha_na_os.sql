-- NIOGEN | supabase/migrations/0359_alerta_bio_aprovada_fecha_na_os.sql | 22/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 22/11 ~15h15 (caso L-219): a venda com OS gravada e instalação agendada continuava na Live como
-- "Biometria APROVADA · seguir no portal: forma de pagamento, agenda e OS → Gravar venda".
-- Causa: esse alerta do GED360 (0247) nasce quando a biometria aprova e a venda ainda não tem OS; ele só saía da Live quando alguém
-- marcava "visto" na ficha. Gravar a OS — que é exatamente o que o alerta pede — não o fechava. Com a venda nascendo sozinha no
-- crédito aprovado (0356), isso passaria a acontecer em todo pedido.
--  (1) Gatilho em vendas: quando a OS é gravada (nio_os passa de vazio a preenchido), o alerta "Biometria APROVADA…" daquela venda
--      é dado como visto pelo sistema (alerta_visto_em = agora, sem autor). Vale para os dois textos do alerta ("seguir no portal" e
--      "abrir o Interesse … e gerar a OS"). Alertas de risco, link expirado etc. não são tocados: esses pedem uma pessoa.
--  (2) Acerto dos que já estão assim (venda com OS e alerta em aberto).
-- Regra 20: (1) não muda situação, vez nem prazo; (2) tira da Live um pedido já cumprido — o que falta fazer continua lá; (3) é o
-- banco que fecha, na gravação da OS, por qualquer caminho (ficha, extensão, robô); (4) fonte: a OS gravada na venda; (5) nada novo
-- a conferir. Regra 15: vale para qualquer parceiro. Desempenho: sem impacto em tela. Tela Live: nenhuma mudança na tela — só deixa
-- de receber um alerta vencido. Cenário X85. Guia do backoffice: uma linha.
begin;

create or replace function public._ged360_alerta_fecha_na_os() returns trigger language plpgsql security definer set search_path = public as $function$
begin
  if coalesce(btrim(new.nio_os), '') <> '' and coalesce(btrim(old.nio_os), '') = '' then
    update public.nio_biometria
       set alerta_visto_em = now()
     where venda_id = new.id and alerta_visto_em is null and alerta like 'Biometria APROVADA%';
  end if;
  return new;
end $function$;
drop trigger if exists vendas_z_alerta_bio_fecha_na_os on public.vendas;
create trigger vendas_z_alerta_bio_fecha_na_os after update of nio_os on public.vendas
  for each row execute function public._ged360_alerta_fecha_na_os();

-- (2) os que já estão com a OS gravada
update public.nio_biometria b
   set alerta_visto_em = now()
  from public.vendas v
 where v.id = b.venda_id and coalesce(btrim(v.nio_os), '') <> ''
   and b.alerta_visto_em is null and b.alerta like 'Biometria APROVADA%';

commit;
