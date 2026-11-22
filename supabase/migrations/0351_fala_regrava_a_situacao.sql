-- NIOGEN | supabase/migrations/0351_fala_regrava_a_situacao.sql | 22/11/2026 — Claude Code (Opus 5.5)
-- Caso L-233 (Maria Aparecida, 21/11), achado depois da 0349 (Ricardo: "Sim, corrige"):
--   A situação gravada (lead_estado) ficava até 10 min atrás da conversa. A cliente escreveu às 21h48 e só virou "responder agora"
--   às 21h50; o time respondeu às 22h04 e só virou "esperando o cliente" às 22h10 — as duas pela varredura (_lead_estado_tick),
--   com o evento genérico prazo:tempo. Motivo: a fala do time e a da Mari, e a do cliente fora de uma espera, entram em
--   mari_turnos sem passar pela porta; a porta do backoffice_responder grava ANTES de a fala existir (ela chega depois, pelo n8n).
--   E o prazo gravado de quem espera o cliente só se refazia quando a situação mudava (o da Maria ficou vazio).
-- O que muda:
--   (1) gatilho mari_turnos_situacao: cada fala de cliente, time ou Mari marca o lead na lead_estado_fila (cliente_escreveu ·
--       time_respondeu · dado:mari_falou). A fila roda no fim da transação (gatilho adiado da 0294), já vendo a fala nova: situação,
--       vez e prazo gravados na hora. Uma marca melhor da mesma transação (evento da porta) continua valendo.
--   (2) Uma vez: regrava as conversas com o time (time_agora e time_esperando), para o prazo de agora (cutucada ou janela, 0349).
-- Regra 20: (1) situação, vez e prazo gravados acompanham a conversa na hora; (2) nenhum estado novo; (3) quem grava é a função do
--   banco (_lead_estado_gravar), com evento e origem 'mari_turnos'; (4) fonte: mari_turnos; (5) conferência: a R14/divergências
--   seguem iguais (devem cair).
-- Desempenho: uma leitura de v_lead_situacao por fala, no fim da transação que grava a fala (como já acontece em todo evento da porta).
-- Cenário X77.
begin;

create or replace function public._turno_marca_situacao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._lead_estado_marcar(new.conversa_id, null::uuid,
    case new.papel when 'lead' then 'cliente_escreveu' when 'humano' then 'time_respondeu' else 'dado:mari_falou' end,
    'mari_turnos');
  return null;
exception when others then
  return null;   -- marcar nunca derruba a fala
end $$;
revoke all on function public._turno_marca_situacao() from public, anon;

drop trigger if exists mari_turnos_situacao on public.mari_turnos;
create trigger mari_turnos_situacao after insert on public.mari_turnos
  for each row when (new.papel in ('lead', 'humano', 'mari'))
  execute function public._turno_marca_situacao();

-- (2) uma vez: o prazo de agora para quem está com o time
do $$
declare e record;
begin
  for e in select conversa_id, venda_id from public.lead_estado where situacao in ('time_agora', 'time_esperando') loop
    perform public._lead_estado_gravar(e.conversa_id, e.venda_id, 'dado:0351', '0351');
  end loop;
end $$;

commit;
