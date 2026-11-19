-- NIOGEN | supabase/rascunhos/0307_projetor_sombra_VOLTA.sql | 19/11/2026 — Claude Code (Opus 5.5), tarefa niogen-passo4-madrugada
-- VOLTA da 0307_projetor_sombra: desliga a sombra do projetor e apaga o que ela criou. Não mexe em nenhuma função de antes
-- (a 0307 não recriou nenhuma) nem na fila (chatwoot_acoes): só tira o gatilho zz_projetor_sombra e os objetos novos.
-- Como usar (só se a sombra mexer em envio ou der erro em função de produção): copiar para supabase/migrations com o próximo
-- número livre (ex.: 0309_projetor_sombra_desligar.sql), rodar o portão com ela e aplicar pela trava:
--   python tests/fluxos/portao.py supabase/migrations/0307_projetor_sombra.sql supabase/migrations/0309_projetor_sombra_desligar.sql
--   python scripts/aplicar_migration.py supabase/migrations/0309_projetor_sombra_desligar.sql
-- (o X40 fica vermelho nessa rodada — é o cenário da sombra; numa volta de emergência, apagar o X40 junto ou aplicar com
-- --sem-portao, que é decisão do Ricardo.)
-- Quer só PARAR de anotar, sem apagar o que foi anotado? Basta a primeira linha (drop trigger).
begin;
drop trigger if exists zz_projetor_sombra on public.chatwoot_acoes;
drop trigger if exists projetor_sombra_julgar on public.projetor_sombra;
drop view if exists public.v_projetor_sombra_divergencias;
drop view if exists public.v_projetor_sombra_resumo;
drop function if exists public._projetor_sombra_anotar();
drop function if exists public._projetor_sombra_julgar();
drop function if exists public._projetor_etiquetas(public.mari_conversas, text);
drop table if exists public.projetor_sombra;
commit;
