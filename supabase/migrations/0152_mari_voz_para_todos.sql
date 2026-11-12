-- NIOGEN | supabase/migrations/0152_mari_voz_para_todos.sql | 13/11/2026 — Claude Code
-- Resumo: libera a resposta em VOZ da Mari para todos os leads (Ricardo, depois do teste da conversa 82 do Chatwoot:
--   "Vamos liberar para todos os leads. São poucos leads chegando ainda e estou monitorando de perto").
--   '' = todos os telefones (n8n/mari/n11f_fala.js). Só a resposta a áudio do cliente; a mídia da cadência
--   (midia_cadencia_telefones) continua só para os telefones de teste.
--   Para voltar: update config_mari_textos set texto = 'teste' where chave = 'audio_resposta_telefones';

update public.config_mari_textos set texto = '' where chave = 'audio_resposta_telefones';
