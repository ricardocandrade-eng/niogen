-- NIOGEN | supabase/migrations/0270_parar_vale_sempre.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Achado do passo 6 (conferência do front, 17/11) — Ricardo: "Sim, corrija aqui".
-- "Cliente pediu para parar" (backoffice_momento 'parar') era RECUSADO em Instalada e Cliente Nio: a tabela só tinha a linha
-- para andamento e Saída, e nas situações finais caía na regra geral ("Venda instalada: o que vem agora é pós-venda").
-- Regra de ouro 6: mensagem automática nunca sai para Não contatar — então o pedido de parar tem de valer SEMPRE
-- (pós-instalação, indicação e régua de pagamento também param). Uma linha na tabela: momento:parar em qualquer situação.
-- Regra 20: nenhum estado novo; o evento continua passando pela porta (0268) e anotado em porta_sombra; conferência: X10 no portão.
begin;

insert into public.config_transicao (evento, de, para, aceito, frase, nota, exige) values
  ('momento:parar', '*', '{nao_contatar,=}', true, null, '0270: o cliente pode pedir para parar em qualquer situação (regra de ouro 6)', null)
on conflict (evento, de) do update set para = excluded.para, aceito = excluded.aceito, frase = excluded.frase, nota = excluded.nota, exige = excluded.exige;

commit;
